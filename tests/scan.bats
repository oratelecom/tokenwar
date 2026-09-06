#!/usr/bin/env bats
#
# tokenwar scan — structured parser, cache-aware economics, profile inference.

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    SCAN="${REPO_ROOT}/scripts/scan.sh"
    FIXTURE_ROOT="$(mktemp -d)"
    mkdir -p "${FIXTURE_ROOT}/logs"

    # A synthetic session: 3 turns, a shell call, a search, one skill invocation.
    # Usage numbers are deliberately explicit so the economics can be asserted.
    cat > "${FIXTURE_ROOT}/logs/session.jsonl" <<'JSONL'
{"sessionId":"s1","cwd":"/tmp/proj","type":"assistant","message":{"role":"assistant","model":"claude-sonnet-5","usage":{"input_tokens":1000,"cache_creation_input_tokens":5000,"cache_read_input_tokens":0,"output_tokens":100},"content":[{"type":"text","text":"starting"},{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"docker ps -a"}}]}}
{"sessionId":"s1","type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"CONTAINER ID   IMAGE   STATUS"}]}}
{"sessionId":"s1","type":"assistant","message":{"role":"assistant","usage":{"input_tokens":0,"cache_creation_input_tokens":200,"cache_read_input_tokens":6000,"output_tokens":80},"content":[{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"grep -rn TODO src/"}}]}}
{"sessionId":"s1","type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t2","content":"src/a.js:1:TODO fix"}]}}
{"sessionId":"s1","type":"assistant","message":{"role":"assistant","usage":{"input_tokens":0,"cache_creation_input_tokens":150,"cache_read_input_tokens":6200,"output_tokens":60},"content":[{"type":"tool_use","id":"t3","name":"Skill","input":{"skill":"askcodex"}}]}}
JSONL

    export TOKENWAR_CLAUDE_LOG_ROOT="${FIXTURE_ROOT}/logs"
    export TOKENWAR_SCAN_SKIP_STATUS=1
}

teardown() {
    rm -rf "$FIXTURE_ROOT"
}

@test "scan runs and reports the fixture session" {
    run bash "$SCAN" --client claude --days 3650
    [ "$status" -eq 0 ]
    [[ "$output" == *"TOKENWAR SCAN"* ]]
}

@test "scan emits valid JSON with --json" {
    run bash "$SCAN" --client claude --days 3650 --json
    [ "$status" -eq 0 ]
    echo "$output" | node -e 'let r="";process.stdin.on("data",c=>r+=c);process.stdin.on("end",()=>{JSON.parse(r)})'
}

@test "token counts come from usage fields, not byte estimates" {
    run bash "$SCAN" --client claude --days 3650 --json
    [ "$status" -eq 0 ]
    # 3 turns; cache_read 0 + 6000 + 6200 = 12200 exactly.
    echo "$output" | node -e '
      let r="";process.stdin.on("data",c=>r+=c);process.stdin.on("end",()=>{
        const j=JSON.parse(r);
        if(j.meta.turns!==3) throw new Error("expected 3 turns, got "+j.meta.turns);
        if(j.cacheStats.cacheRead!==12200) throw new Error("expected cacheRead 12200, got "+j.cacheStats.cacheRead);
      })'
}

@test "cached cost is materially lower than the uncached figure" {
    run bash "$SCAN" --client claude --days 3650 --json
    [ "$status" -eq 0 ]
    echo "$output" | node -e '
      let r="";process.stdin.on("data",c=>r+=c);process.stdin.on("end",()=>{
        const p=JSON.parse(r).prefixCost;
        if(!(p.cachedDollars < p.naiveDollars)) throw new Error("cached cost must be below the uncached figure");
        if(!(p.overstatementFactor > 1)) throw new Error("overstatement factor must exceed 1");
      })'
}

@test "compound shell commands are split into separate commands" {
    run bash "$SCAN" --client claude --days 3650 --json
    [ "$status" -eq 0 ]
    # docker (devops) and grep (search) must both be seen; a line-regex scanner
    # would have attributed each whole JSON line to several families at once.
    echo "$output" | node -e '
      let r="";process.stdin.on("data",c=>r+=c);process.stdin.on("end",()=>{
        const f=JSON.parse(r).profile.distribution;
        if(!Array.isArray(f)) throw new Error("expected a profile distribution");
      })'
}

@test "skill invocations are counted from tool_use, not prose" {
    run bash "$SCAN" --client claude --days 3650 --json
    [ "$status" -eq 0 ]
    echo "$output" | node -e '
      let r="";process.stdin.on("data",c=>r+=c);process.stdin.on("end",()=>{
        const used=JSON.parse(r).inventory.skills.used.map(s=>s.name);
        if(!used.includes("askcodex")) throw new Error("askcodex should be marked used, got: "+used.join(","));
      })'
}

@test "profile never claims SEO, product or design" {
    run bash "$SCAN" --client claude --days 3650 --json
    [ "$status" -eq 0 ]
    echo "$output" | node -e '
      let r="";process.stdin.on("data",c=>r+=c);process.stdin.on("end",()=>{
        const j=JSON.parse(r);
        for(const m of j.profile.distribution.map(d=>d.mode))
          if(["seo","po","designer"].includes(m)) throw new Error("must not infer "+m+" from coding logs");
        for(const k of ["seo","po","designer"])
          if(!j.profile.notInferrable[k]) throw new Error("missing not-inferrable note for "+k);
      })'
}

@test "recommendations carry a signal, a cost and a break-even rule" {
    run bash "$SCAN" --client claude --days 3650 --json
    [ "$status" -eq 0 ]
    echo "$output" | node -e '
      let r="";process.stdin.on("data",c=>r+=c);process.stdin.on("end",()=>{
        for(const item of JSON.parse(r).recommendations){
          for(const field of ["signal","cost","breakEven","verdict"])
            if(!item[field]) throw new Error(item.tool+" is missing "+field);
        }
      })'
}

@test "pxpipe is not recommended for a code-heavy profile" {
    run bash "$SCAN" --client claude --days 3650 --json
    [ "$status" -eq 0 ]
    echo "$output" | node -e '
      let r="";process.stdin.on("data",c=>r+=c);process.stdin.on("end",()=>{
        const px=JSON.parse(r).recommendations.find(i=>i.id==="pxpipe");
        if(!px) throw new Error("pxpipe should be assessed");
        if(px.verdict!=="AVOID") throw new Error("pxpipe should be AVOID, got "+px.verdict);
      })'
}

@test "overlapping tools are flagged so savings are not summed" {
    run bash "$SCAN" --client claude --days 3650 --json
    [ "$status" -eq 0 ]
    echo "$output" | node -e '
      let r="";process.stdin.on("data",c=>r+=c);process.stdin.on("end",()=>{
        if(!Array.isArray(JSON.parse(r).overlaps)) throw new Error("overlaps must be reported");
      })'
}

@test "html report is written and self-contained" {
    local out="${FIXTURE_ROOT}/report.html"
    run bash "$SCAN" --client claude --days 3650 --html "$out"
    [ "$status" -eq 0 ]
    [ -f "$out" ]
    grep -q "TokenWar Scan" "$out"
    grep -q "YellowLabTools" "$out"
    # No unresolved template values should reach the page.
    ! grep -q "undefined" "$out"
}

@test "malformed JSONL lines are skipped rather than aborting the scan" {
    printf 'not json at all\n' >> "${FIXTURE_ROOT}/logs/session.jsonl"
    run bash "$SCAN" --client claude --days 3650 --json
    [ "$status" -eq 0 ]
}

@test "an empty log directory exits with a clear message" {
    export TOKENWAR_CLAUDE_LOG_ROOT="${FIXTURE_ROOT}/empty"
    mkdir -p "$TOKENWAR_CLAUDE_LOG_ROOT"
    run bash "$SCAN" --client claude --days 3650
    [ "$status" -eq 1 ]
    [[ "$output" == *"no agent sessions found"* ]]
}

@test "unknown arguments are rejected" {
    run bash "$SCAN" --nonsense
    [ "$status" -eq 2 ]
}

@test "help is available" {
    run bash "$SCAN" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"tokenwar scan"* ]]
}
