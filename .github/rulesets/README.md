# Branch ruleset for `main`

`protect-main.json` is the ruleset applied to this repository, kept here so
the rule is reviewed and versioned like everything else. Apply or update it
with `bootstrap/ci-access/install.sh`.

| Rule | Effect |
|---|---|
| Pull request required | Nobody, including the owner, can push straight to `main` |
| Required status checks | `lint and test`, `build backend`, `build frontend` and `scan repository` must pass before a merge |
| No force-push, no deletion | History on `main` cannot be rewritten |
| Bypass: deploy keys only | The deploy workflow commits image tags with a dedicated write deploy key; nothing else bypasses the rules |

**Required approvals is 0** because this repository has a single maintainer,
and GitHub does not let an author approve their own pull request — a value of
1 would make every merge impossible. The human approval in this project is on
the production deployment instead (the `prod` environment's required
reviewer). With a second maintainer this should be raised to 1.

"Require branches to be up to date" is off: the deploy workflow commits to
`main` after every release, so every open pull request would constantly be
out of date.
