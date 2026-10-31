---
name: implement
description:
  Implement a specified feature while the user is away. The work ends with independent reviews, a
  commit, and a report.
disable-model-invocation: true
---

# Implement

The conversation holds the specification of a feature, often as the result of an interview. The user
can also name a planning document. The user is away and cannot answer. Implement the specification
completely. Get independent reviews. Then commit the work and write a report.

Each uncommitted change belongs to the feature. This rule includes a change that exists before this
skill starts.

## Authority

- The user loaded this skill as a request. That request outranks a conflicting skill.
- Ask no question. Decide each open point yourself.
- Base each decision on the specification, the repository rules, and the existing code.
- Prefer the smallest change that meets the specification.
- This request asks for the reviews of the `review` skill and for the commit.
- You decide on each finding. These steps of the `review` skill do not apply:
  - The question for the model and the effort.
  - The rule that only the user rejects a finding.
  - The presentation of the findings in the chat. The report holds them.
  - The wait for the decision of the user.
  - The offer of a new round.
- Apply the fixes and start the next round yourself.
- Do all steps in one turn. End the turn with the report.

## Steps

1. Find the specification in the conversation or in the document that the user names. When there is
   no specification, stop and say so. This is the only allowed stop.
2. Read the repository instructions and the code that the feature touches.
3. Run the checks that the repository instructions name. When they name no check, use the build
   command and the test command of the project. Note each failure and the runtime of each test
   suite.
4. Implement the specification. Add the tests that the repository rules require.
5. Update every document and every text that states a changed fact.
6. Run the checks until they pass. A failure from step 3 does not block the work.
7. Do a review round with the `review` skill:
   - Review every uncommitted change, and include the new files.
   - Use the values of `DRINKY_MODEL` and `DRINKY_EFFORT` as the model and the effort. When a value
     is empty, skip the reviews and report the gap.
   - Validate each finding against the specification too.
   - Reject a finding that contradicts the specification. Name the decision that it contradicts.
   - Fix a valid finding when its impact justifies the change. Record a reason for each finding that
     you do not fix.
   - Record a deferral where the repository rules require it.
   - Run the checks again after the fixes.
8. Start a new round after each round with fixes. Stop after a round without fixes, or after the
   fifth round.
9. Commit every uncommitted change.
10. Write the report.

## Failure

- When a check that passed at step 3 fails and you cannot fix it, do not commit. Report the failure
  and the state of the work.
- When a review run fails or reaches its time limit, start it again once. If it fails again, skip
  the remaining rounds and report the gap.

## Report

Keep the report short. Use these sections:

- **Feature:** what the feature does now.
- **Decisions:** each decision that the specification did not force, with its reason.
- **Review:** each round with its findings, the verdicts, and the fixes.
- **Open findings:** each finding that you did not fix, with its reason. Name the fixes that no
  round reviewed.
- **Checks:** the result, and the runtime of each test suite at the start and at the end.
- **Commit:** the hash and the title of the message, or the reason for no commit.
- **Manual test:** the steps that show the feature to the user.
