// Workload-mode inference from structured tool-call evidence.
//
// Two deliberate constraints:
//
// 1. Output is a distribution, never a single label. Real users mix modes, and
//    a machine whose own histogram is Bash-dominant would be mislabelled by any
//    winner-takes-all rule.
// 2. Modes that coding-agent logs cannot see are reported as not-inferrable
//    rather than guessed. Absence of signal is not signal: a product owner who
//    never opens a coding agent leaves no trace, and a `curl` against a sitemap
//    looks identical whether an SEO or a developer typed it.

// Modes we can actually evidence from a coding agent's own logs.
export const INFERRABLE_MODES = ["dev", "devops", "architect", "testing"];

// Modes whose real work happens in tools these logs never observe. Listed so
// the report can say so explicitly instead of silently omitting them.
export const NOT_INFERRABLE_MODES = {
  seo: "SEO work lives in Search Console, Ahrefs and content tools. A curl against a sitemap is indistinguishable from a developer checking a route.",
  po: "Product work lives in Jira, Linear and meetings. A PO who never opens a coding agent produces no logs at all.",
  designer: "Design work lives in Figma. A .css edit means a front-end developer at least as often as a designer.",
};

// Minimum evidence before a mode may be claimed at all. Gates run before
// scoring so a single stray `docker ps` cannot flip the profile.
const GATES = {
  devops: (f) => f.devopsCommands >= 3 && f.distinctDevopsBinaries >= 2,
  testing: (f) => f.testCommands >= 5,
  dev: (f) => f.sourceEdits >= 3,
  architect: (f) => f.distinctProjects >= 2 || f.agentCalls >= 3,
};

const CONFIDENCE_FLOOR = 0.15;

export function buildFeatures(aggregate) {
  const families = aggregate.bashFamilies;
  const tools = aggregate.toolCalls;
  const heads = aggregate.bashHeads;
  const get = (map, key) => map.get(key) || 0;

  const bashTotal = [...families.values()].reduce((sum, value) => sum + value, 0) || 1;

  const devopsBinaries = ["ssh", "scp", "docker", "kubectl", "systemctl", "journalctl",
    "terraform", "ansible", "gcloud", "aws", "az", "caddy", "nginx", "rsync", "helm"];
  const distinctDevopsBinaries = devopsBinaries.filter((binary) => get(heads, binary) > 0).length;

  const sourceExtensions = ["py", "js", "ts", "tsx", "jsx", "go", "rs", "java", "rb", "php", "c", "cpp", "h", "swift", "kt"];
  const infraExtensions = ["yml", "yaml", "conf", "tf", "dockerfile", "service", "ini", "toml"];
  const docExtensions = ["md", "rst", "adoc", "txt"];

  const extensionSum = (list) =>
    list.reduce((sum, ext) => sum + get(aggregate.fileExtensions, ext), 0);

  const edits = get(tools, "Edit") + get(tools, "NotebookEdit");
  const writes = get(tools, "Write");
  const reads = get(tools, "Read") + aggregate.lanes.read.calls + aggregate.lanes.fileRead.calls;
  const searches = get(tools, "Grep") + get(tools, "Glob") + aggregate.lanes.search.calls;

  return {
    bashTotal,
    devopsCommands: get(families, "devops"),
    devopsShare: get(families, "devops") / bashTotal,
    distinctDevopsBinaries,
    testCommands: get(families, "test"),
    testShare: get(families, "test") / bashTotal,
    buildCommands: get(families, "build"),
    buildShare: get(families, "build") / bashTotal,
    vcsShare: get(families, "vcs") / bashTotal,
    searchShare: get(families, "search") / bashTotal,
    readShare: get(families, "read") / bashTotal,
    sourceEdits: extensionSum(sourceExtensions),
    infraEdits: extensionSum(infraExtensions),
    docEdits: extensionSum(docExtensions),
    edits,
    writes,
    reads,
    searches,
    editWriteRatio: edits + writes > 0 ? edits / (edits + writes) : 0,
    readToEditRatio: edits > 0 ? reads / edits : reads,
    agentCalls: get(tools, "Agent") + get(tools, "Task"),
    distinctProjects: aggregate.cwds.size,
    sessions: aggregate.sessions,
  };
}

// Each rule contributes weighted evidence. Weights follow the evidence family:
// a role-specific binary is stronger than a ratio, which is stronger than a
// single artifact.
const RULES = {
  devops: [
    { weight: 3, test: (f) => f.devopsShare >= 0.20, why: (f) => `${pct(f.devopsShare)} of shell commands are infrastructure verbs` },
    { weight: 3, test: (f) => f.distinctDevopsBinaries >= 3, why: (f) => `${f.distinctDevopsBinaries} distinct infrastructure binaries used` },
    { weight: 2, test: (f) => f.infraEdits >= 3, why: (f) => `${f.infraEdits} infrastructure/config files edited` },
    { weight: 1, test: (f) => f.devopsShare >= 0.10, why: (f) => `sustained infrastructure command use` },
  ],
  dev: [
    { weight: 3, test: (f) => f.sourceEdits >= 10, why: (f) => `${f.sourceEdits} source files written or edited` },
    { weight: 2, test: (f) => f.buildShare >= 0.10, why: (f) => `${pct(f.buildShare)} of shell commands are build/package managers` },
    { weight: 2, test: (f) => f.editWriteRatio >= 0.4, why: (f) => `edits outnumber fresh writes (maintenance work)` },
    { weight: 1, test: (f) => f.vcsShare >= 0.05, why: () => `regular version-control activity` },
  ],
  testing: [
    { weight: 3, test: (f) => f.testShare >= 0.10, why: (f) => `${pct(f.testShare)} of shell commands are test runners` },
    { weight: 3, test: (f) => f.testCommands >= 20, why: (f) => `${f.testCommands} test-runner invocations` },
    { weight: 1, test: (f) => f.testCommands >= 5, why: (f) => `${f.testCommands} test-runner invocations` },
  ],
  architect: [
    { weight: 3, test: (f) => f.readToEditRatio >= 5 && f.reads >= 10, why: (f) => `reads outnumber edits ${f.readToEditRatio.toFixed(1)}:1 (exploration over production)` },
    { weight: 2, test: (f) => f.distinctProjects >= 4, why: (f) => `${f.distinctProjects} distinct projects touched` },
    { weight: 2, test: (f) => f.agentCalls >= 5, why: (f) => `${f.agentCalls} delegated subagent investigations` },
    { weight: 1, test: (f) => f.docEdits >= 5, why: (f) => `${f.docEdits} documentation files written` },
  ],
};

function pct(ratio) {
  return `${(ratio * 100).toFixed(1)}%`;
}

export function inferProfile(aggregate) {
  const features = buildFeatures(aggregate);
  const scored = [];

  for (const mode of INFERRABLE_MODES) {
    const gate = GATES[mode];
    const gatePassed = gate ? gate(features) : true;
    let score = 0;
    const evidence = [];
    for (const rule of RULES[mode] || []) {
      if (rule.test(features)) {
        score += rule.weight;
        evidence.push({ weight: rule.weight, why: rule.why(features) });
      }
    }
    scored.push({ mode, score: gatePassed ? score : 0, gatePassed, evidence });
  }

  const total = scored.reduce((sum, item) => sum + item.score, 0);
  const distribution = scored
    .map((item) => ({ ...item, confidence: total > 0 ? item.score / total : 0 }))
    .filter((item) => item.confidence >= CONFIDENCE_FLOOR)
    .sort((left, right) => right.confidence - left.confidence);

  // Renormalize after dropping low-confidence modes so the reported shares sum
  // to 1 and can be read as a distribution.
  const kept = distribution.reduce((sum, item) => sum + item.score, 0);
  for (const item of distribution) item.confidence = kept > 0 ? item.score / kept : 0;

  return {
    features,
    distribution,
    primary: distribution[0]?.mode || "unknown",
    determinate: distribution.length > 0 && distribution[0].confidence >= 0.35,
    notInferrable: NOT_INFERRABLE_MODES,
  };
}
