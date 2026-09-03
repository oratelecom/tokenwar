#!/usr/bin/env bats

setup() {
    REPORT_DIR="$BATS_TEST_DIRNAME/../study-usecase"
    REPORT="$REPORT_DIR/index.html"
}

@test "study-usecase publishes the role-based agent stack report" {
    [ -f "$REPORT" ]
    grep -q "Oui, prenez les trois" "$REPORT"
    grep -q "Agent de code" "$REPORT"
    grep -q "Agent d’architecture" "$REPORT"
    grep -q "Agent DevOps / SRE" "$REPORT"
    grep -q "Claude‑mem" "$REPORT"
}

@test "study-usecase ships every relative evidence link" {
    python3 - "$REPORT" <<'PY'
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote
import sys

report = Path(sys.argv[1]).resolve()

class Links(HTMLParser):
    def __init__(self):
        super().__init__()
        self.hrefs = []

    def handle_starttag(self, tag, attrs):
        href = dict(attrs).get("href")
        if href:
            self.hrefs.append(href)

links = Links()
links.feed(report.read_text())
missing = []
for href in links.hrefs:
    if href.startswith(("#", "http://", "https://", "mailto:")):
        continue
    target = unquote(href.split("#", 1)[0])
    if target and not (report.parent / target).exists():
        missing.append(href)
if missing:
    raise SystemExit(f"missing evidence links: {missing}")
PY
}

@test "study-usecase source-code evidence uses immutable GitHub commits" {
    ! grep -Eq 'href="(graphify|serena|openwiki)/' "$REPORT"
    grep -q "Graphify-Labs/graphify/blob/33362d969292b57eda82f3fbd9eb5f3f5bc9bbc2" "$REPORT"
    grep -q "oraios/serena/blob/801a388c2b7a6a8998f313291678b1609664e794" "$REPORT"
    grep -q "langchain-ai/openwiki/blob/5c69350c757f3361360de26fc170e1aab6843bbc" "$REPORT"
}
