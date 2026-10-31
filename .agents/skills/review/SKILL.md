---
name: review
description:
  Get an independent review of changes that the current agent implemented. Use it only when the user
  asks to assess those changes. A second agent starts without the implementation context to reduce
  bias. Assess other work directly without this skill. Validate each finding and recommend which
  fixes to apply.
metadata:
  drinky-run: hidden
---

# Review

A second Drinky agent reviews your changes without the implementation conversation. Validate each
finding against the code and recommend which fixes to apply. The user decides what to fix.

## When to use this skill

Use this skill only when the user requests an assessment of changes that you implemented. A separate
reviewer can find mistakes that your implementation assumptions hide.

For work that you did not implement, assess it directly without this skill.

Start a review only at the request of the user. Do not start one automatically after implementation.

## Inside a run

Read the environment first:

```sh
printf 'run=%s model=%s effort=%s\n' "$DRINKY_RUN" "$DRINKY_MODEL" "$DRINKY_EFFORT"
```

When `DRINKY_RUN` is set, you are the reviewer. Drinky refuses another run. Do the review yourself,
and ignore the rest of this skill.

## Steps

1. Take the scope from the request of the user. Without an explicit scope, review only your
   implementation changes, including new files. Include other changes only when the user requests
   them. Identify the relevant files and changes before you start the reviewer. When a file contains
   unrelated changes, specify the changes to review.
2. In the first round of the conversation, ask one question for the model and the effort. Offer
   `DRINKY_MODEL` and `DRINKY_EFFORT` as the default. When a variable is empty, ask for that value
   without a default. The user confirms the default or names other values. Show the output of
   `drinky models` only on request. In a later round, use the model and the effort of the last round
   without a question. Use other values only when the user names them.
3. Start the reviewer with the `bash` tool and a `timeout_seconds` value of 3600:

   ```sh
   drinky run --model "$DRINKY_MODEL" --effort "$DRINKY_EFFORT" <<'EOF'
   Review only these changes:
   <Files and changes to review>
   You have no context about the task. Judge the work from the files alone.
   Change no files.
   EOF
   ```

   Put the values of step 2 in place of the two variables. Replace `<Files and changes to review>`
   with the scope from step 1. Keep the quotes around the heredoc delimiter, so that the shell keeps
   the prompt unchanged. Add no intent and no summary of the task to the prompt.

4. Validate each finding against the code. Include each finding that the reviewer marks as optional.
   Read the files that the finding names.
5. Treat a finding as rejected only when the user explicitly rejects it. Leave an unaddressed
   finding undecided. In a later round, a finding can repeat an earlier rejected finding. Mark it as
   rejected earlier, and name the earlier verdict. Check it again only when the code that it names
   changed since that round.
6. Present one entry for each finding. Do not repeat the full text of the review.
   - **Finding:** the finding in one line.
   - **Verdict:** valid, partly valid, invalid, or rejected earlier.
   - **Evidence:** the file and the line, the rule, or the command output that decides the verdict.
   - **Fix:** the change that you propose, or none.
   - **Recommendation:** fix, defer, or skip, with a brief reason based on impact, risk, and effort.
7. List the recommended fixes in priority order. Do not recommend a fix solely because a finding is
   valid or optional.
8. Stop and wait for the decision of the user. Change no file before that decision. When you
   recommend at least one fix, end the answer with this question:
   `Do you want me to apply the recommended fixes?` Treat a reply of `yes` as a decision for every
   recommended fix.
9. Apply the fixes that the user chooses. Then offer a new round in one sentence that names the
   model and the effort of that round, and wait.

## Failure

A failed run ends with exit code 1 and writes its error to stderr. Report that error. A run that
stops at a limit still writes its last reply text to stdout. That text can hold no review. Validate
any review text that arrived, and mark the result as incomplete.

The `bash` tool can stop the run at its time limit. The run then writes no reply text. Report the
timeout, and wait for the decision of the user.
