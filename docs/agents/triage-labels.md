# Triage Labels

The skills speak in terms of five canonical triage roles. This file maps those roles to the actual label strings used in this repo's issue tracker.

## claudeclaw-os labels

| Label in mattpocock/skills | Label in our tracker | Meaning                                  |
| -------------------------- | -------------------- | ---------------------------------------- |
| `needs-triage`             | `needs-triage`       | Maintainer needs to evaluate this issue  |
| `needs-info`               | `needs-info`         | Waiting on reporter for more information |
| `ready-for-agent`          | `ready-for-agent`    | Fully specified, ready for an AFK agent  |
| `ready-for-human`          | `ready-for-human`    | Requires human implementation            |
| `wontfix`                  | `wontfix`            | Will not be actioned                     |

## groit labels (cross-repo)

The groit repo uses a different vocabulary established by PO and architect:

| mattpocock/skills role | groit label          | Notes                                    |
| ---------------------- | -------------------- | ---------------------------------------- |
| `ready-for-agent`      | `lane-ready`         | Lane spec complete, dev-agent can pick up |
| `needs-triage`         | (no label)           | PO triages via slice workflow             |
| `wontfix`              | (close with comment) | No dedicated label                        |

Additionally, groit uses `claimed-by:architect`, `claimed-by:dev-agent` to track ownership.

When a skill mentions a role (e.g. "apply the AFK-ready triage label"), use the corresponding label string from the relevant table above.
