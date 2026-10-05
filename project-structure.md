# Consuming Project Structure

```text
my-application/
├── AGENTS.md
├── .agents/
│   ├── project/
│   │   ├── system-overview.md
│   │   ├── architecture/
│   │   ├── domains/
│   │   ├── data/
│   │   └── design/
│   ├── decisions/
│   ├── specs/
│   │   ├── active/
│   │   └── archive/
│   ├── learnings/
│   ├── failures/
│   └── regressions/
├── src/
├── tests/
└── package.json
```

Project context = how the application works.
Work spec = what this body of work changes.
ADR = why an important decision was made.
Learning = what was discovered.
Regression = executable memory of a failure/required behavior.
