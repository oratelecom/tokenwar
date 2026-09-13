#!/usr/bin/env bats
#
# Unit tests for the shell-command tokenizer and the cache-aware cost model.
# These cover the two places where the old regex scanner was unsound: attributing
# a command to a family, and pricing a cached prefix block.

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    LIB="${REPO_ROOT}/scripts/lib"
}

run_node() {
    node --input-type=module -e "$1"
}

@test "commandHead unwraps sudo and env assignments" {
    run run_node "
      import {commandHead} from '${LIB}/parse.mjs';
      const cases = [
        ['sudo systemctl restart nginx', 'systemctl'],
        ['FOO=bar BAZ=qux python3 script.py', 'python3'],
        ['sudo -u deploy docker ps', 'docker'],
        ['/usr/local/bin/rg pattern', 'rg'],
        ['timeout 30 pytest -q', 'pytest'],
      ];
      for (const [input, expected] of cases) {
        const got = commandHead(input);
        if (!got || got.head !== expected) {
          throw new Error(\`\${input} -> \${got && got.head}, expected \${expected}\`);
        }
      }
    "
    [ "$status" -eq 0 ]
}

@test "commandHead ignores shell syntax fragments" {
    run run_node "
      import {commandHead} from '${LIB}/parse.mjs';
      for (const fragment of ['do', 'done', 'fi', 'then', '}', '\$(pwd)']) {
        if (commandHead(fragment) !== null) throw new Error('should ignore: ' + fragment);
      }
    "
    [ "$status" -eq 0 ]
}

@test "quoted arguments do not leak into the command head" {
    run run_node "
      import {commandHead} from '${LIB}/parse.mjs';
      const got = commandHead('grep \"git commit\" file.txt');
      if (!got || got.head !== 'grep') throw new Error('expected grep, got ' + (got && got.head));
    "
    [ "$status" -eq 0 ]
}

@test "compound commands split on pipes and operators" {
    run run_node "
      import {splitCommands} from '${LIB}/parse.mjs';
      const heads = splitCommands('git status | grep modified && docker ps; ls -la').map((c) => c.head);
      const expected = ['git', 'grep', 'docker', 'ls'];
      if (heads.join(',') !== expected.join(',')) {
        throw new Error('got ' + heads.join(',') + ', expected ' + expected.join(','));
      }
    "
    [ "$status" -eq 0 ]
}

@test "classifyCommand separates infrastructure from build tooling" {
    run run_node "
      import {classifyCommand} from '${LIB}/parse.mjs';
      const cases = [['docker','devops'],['kubectl','devops'],['ssh','devops'],
                     ['pytest','test'],['npm','build'],['git','vcs'],
                     ['rg','search'],['cat','read'],['curl','web']];
      for (const [head, family] of cases) {
        const got = classifyCommand(head);
        if (got !== family) throw new Error(head + ' -> ' + got + ', expected ' + family);
      }
    "
    [ "$status" -eq 0 ]
}

@test "a prose mention of a command is not a command" {
    run run_node "
      import {commandHead} from '${LIB}/parse.mjs';
      // The old scanner matched /\\bgit\\b/ anywhere on a line, so this sentence
      // counted as version-control activity. Tokenizing argv[0] does not.
      const got = commandHead('echo \"you should run git bisect here\"');
      if (!got || got.head !== 'echo') throw new Error('expected echo, got ' + (got && got.head));
    "
    [ "$status" -eq 0 ]
}

@test "a cached prefix block costs far less than the uncached multiplication" {
    run run_node "
      import {prefixBlockCost, pricingFor} from '${LIB}/economics.mjs';
      const price = pricingFor('claude-opus');
      const r = prefixBlockCost({blockTokens: 5796, turns: 158, price, cacheWriteTurns: 1});
      if (r.naiveTokens !== 5796 * 158) throw new Error('naive token count is wrong');
      if (!(r.overstatementFactor > 5)) {
        throw new Error('expected a large overstatement, got ' + r.overstatementFactor);
      }
      // One write at 1.25x plus 157 reads at 0.1x.
      const expected = 5796 * (1.25 + 157 * 0.1);
      if (Math.abs(r.equivalentTokens - expected) > 1) {
        throw new Error('equivalent tokens ' + r.equivalentTokens + ', expected ' + expected);
      }
    "
    [ "$status" -eq 0 ]
}

@test "window occupancy is not discounted by caching" {
    run run_node "
      import {windowOccupancy} from '${LIB}/economics.mjs';
      const o = windowOccupancy({blockTokens: 5796, contextWindow: 200000, firstRequestTokens: 6901});
      if (Math.abs(o.windowShare - 0.02898) > 0.0001) throw new Error('window share wrong: ' + o.windowShare);
      if (!(o.firstRequestShare > 0.8)) throw new Error('first-request share wrong: ' + o.firstRequestShare);
    "
    [ "$status" -eq 0 ]
}

@test "invalidating the prefix costs 12.5x a cache read" {
    run run_node "
      import {invalidationCost, pricingFor} from '${LIB}/economics.mjs';
      const price = pricingFor('claude-opus');
      const r = invalidationCost({prefixTokens: 30000, price});
      const ratio = r.rewrite / r.read;
      if (Math.abs(ratio - 12.5) > 0.01) throw new Error('expected a 12.5x step, got ' + ratio);
    "
    [ "$status" -eq 0 ]
}

@test "profile inference returns a distribution, never a bare label" {
    run run_node "
      import {inferProfile} from '${LIB}/profile.mjs';
      const aggregate = {
        bashFamilies: new Map([['devops', 50], ['read', 20], ['search', 10]]),
        toolCalls: new Map([['Bash', 80], ['Edit', 5]]),
        bashHeads: new Map([['docker', 20], ['ssh', 20], ['kubectl', 10]]),
        fileExtensions: new Map([['yml', 5]]),
        lanes: {read: {calls: 20, bytes: 0}, search: {calls: 10, bytes: 0}, fileRead: {calls: 0, bytes: 0}},
        cwds: new Set(['/a']),
        sessions: 5,
      };
      const p = inferProfile(aggregate);
      if (!Array.isArray(p.distribution)) throw new Error('distribution must be an array');
      const total = p.distribution.reduce((sum, item) => sum + item.confidence, 0);
      if (p.distribution.length && Math.abs(total - 1) > 0.01) {
        throw new Error('confidences must sum to 1, got ' + total);
      }
      for (const item of p.distribution) {
        if (!item.evidence.length) throw new Error(item.mode + ' has no evidence');
      }
    "
    [ "$status" -eq 0 ]
}
