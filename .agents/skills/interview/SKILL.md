---
name: interview
description:
  Interview the user one question at a time to shape a complex design, or to check an existing
  document or feature against the intent of the user. Use it when the user asks for an interview.
  Offer it before a plan whose user experience, edge cases, or trade-offs belong to the user. Load
  it before the first question.
---

# Interview

The user knows what the product must do. You know what the code does. The interview joins the two.
You never invent the user experience, a default, or a user-facing name for the user.

The user gives a short goal. You ask questions until you have a complete picture. Then you write the
result down.

The rules give the structure. The conversation stays natural. Adapt when the user agrees, raises a
new idea, or asks for other examples.

Three rules never bend: one question per message, one decision per question, and at most three
sentences of context.

## Trigger

- The user starts the interview. It costs the time of the user, so that decision belongs to the
  user.
- You can offer an interview in one sentence with the reason, and then wait for a yes. A plan, a
  design note, a skill, and a backlog entry are good cases.
- Skip the interview for a one-line idea, a typo, or a fix that the code fully explains.

## Rules

- Read the relevant code, the tests, and the documents first. Every question must rest on a fact
  from the repository. Never ask something the code already answers.
- Ask one question per message. Nothing else goes into that message.
- Ask as many questions as you need. There is no target count.
- Never mix two decisions into one question.
- Number the questions with a counter that runs through the whole interview.
- Give an option list of two to four options. The options must exclude each other. Order them from
  the smallest change to the largest change.
- Always recommend one option and give the reason in one or two sentences.
- Ask the user when the code alone cannot decide something. Never fill the hole yourself.
- A question about a user-facing name or string also carries options. Each option must obey the
  style rules and the width limits. The free text of the user outranks the list.
- Code identifiers belong to you. The style rules decide them, so do not ask about them.
- Write no code and change no file during the interview. A direct request from the user outranks
  this rule.

## Answers

The user answers with a number, with free text, or with both.

- Confirm each answer in one short sentence before the next question. Rephrase the decision in your
  own words, so the user sees what you understood.
- Treat free text as a new constraint. Put the constraint into the next option list.
- Say which earlier decisions an answer cancels, and ask those questions again with a new number.
- Ask again when an answer stays unclear. Do not guess.
- Take your own recommended option when the user hands the decision back to you. Confirm it as
  decided, and mark it as your choice in the summary.

## Form

Use this exact form. Keep the context to three short sentences at most.

```
### Question 7

A list can hold more items than the window shows. The selection stops at the last visible row
today.

What must happen when the selection moves below the last visible row?

1. Keep the selection on the last visible row.
2. Scroll the list by one row and keep the selection at the bottom.
3. Move the selection to the first row of the next page.

I recommend option 2. The user keeps one steady reading position, and one key press still moves one
row.
```

## End

Stop when no open decision remains. Then give a short summary of the decisions in order, in the
chat. Mark every decision that you took for the user.

The next step comes out of the conversation. Often the target is already clear. There is no
confirmation gate, because git can undo a wrong change.
