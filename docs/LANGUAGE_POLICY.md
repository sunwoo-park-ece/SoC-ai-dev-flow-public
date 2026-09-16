# Language Policy

## Default / Authoritative Language

English is the default and canonical engineering language of this repository.

Unless a document explicitly states otherwise:

```text
*.md       = canonical / authoritative
*.ko.md    = Korean companion translation for human readability
```

The `spec/` tree uses a stricter placement convention:

```text
spec/NN_name.md          = canonical / authoritative English specification
spec/kor/NN_name.ko.md   = Korean companion specification
```

The numeric prefix is used for specification reading/dependency order and does not change the authority model.

If the English and Korean documents conflict, the English document is authoritative.

This rule exists to keep one unambiguous contract for architecture, implementation, verification, scripts, and AI agents.

## Why English Is Canonical

The repository contains RTL, firmware, protocol terminology, register semantics, assertions, verification artifacts, tool output, and AI-agent instructions. Keeping the canonical engineering contract in English reduces ambiguity around technical terms and prevents two independently evolving specifications from becoming competing sources of truth.

All agents must reason from and implement against the canonical English document first.

## Korean Companion Documents

Korean companion documents exist for:
- developer readability
- design review
- portfolio preparation
- Korean recruiting / technical interview preparation
- major engineering narratives and milestone summaries

A Korean companion should preserve the meaning of the English source. It may improve Korean readability, but it must not introduce new requirements, register semantics, measurements, or architecture decisions.

Every `.ko.md` companion should state near the top that the English document is authoritative.

For specifications specifically, Korean companions shall be stored under `spec/kor/` with the same numeric prefix and logical basename as the English source.

## Translation Selection Policy

Create a `.ko.md` companion when the document is meaningfully human-facing, especially:
- repository overview / README
- agent roles and workflow rules
- architecture overview documents
- major milestone engineering reports
- portfolio / interview summaries
- major design-decision documents where Korean review has clear value

A Korean companion is optional and normally unnecessary for documents that are primarily machine-, protocol-, or tool-facing, such as:
- register-level protocol contracts
- assertion definitions
- generated tool reports
- raw build / regression logs
- short directory-only README files
- script-specific implementation notes
- machine-generated metrics

Do not create translations merely to make every Markdown file bilingual.

## Agent Rules

All project agents must follow these rules:

1. Read the English canonical document when making architecture, implementation, verification, integration, or reporting decisions.
2. For specification work, treat `spec/NN_*.md` as authoritative and `spec/kor/NN_*.ko.md` as explanatory companions.
3. Never use a `.ko.md` translation as a reason to override the English source.
4. When changing a canonical English document that has a Korean companion, update the `.ko.md` companion in the same task whenever practical.
5. If the translation is stale or uncertain, keep the English document correct first and explicitly mark the Korean companion as needing synchronization rather than guessing.
6. Do not create a Korean translation for generated/raw tool evidence unless it materially improves human review.
7. Quantitative results must remain identical across language variants; units, values, commit references, and evidence links must not diverge.
8. Technical identifiers, signal names, register names, paths, commands, and code should normally remain unchanged in the Korean companion.
9. New authoritative requirements must always be introduced in the English canonical document first.
10. If specification files are renumbered, all repository links and companion filenames shall be updated in the same structural change.

## Core Principle

```text
English defines the contract.
Korean improves human readability.
One engineering truth, two reading surfaces.
```
