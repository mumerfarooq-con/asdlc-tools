# Access rules

What grants access to what in this project. The planner reads this file on
every `/asdlc:jira-run` and cites the entries a ticket touches. Code shows
where a check is; this file says what the check is *for*, so a change made
for display can't quietly change who gets in.

- One entry per protected thing (a video, a live event, paid content, an admin action...).
- A human fills and confirms each entry. An agent may draft one; it isn't a rule until a human confirms it.
- A plan that changes an access rule must update its entry here as part of its changes.
- If a ticket touches access to something with no entry here, the planner raises an
  open question: "access rules missing for <thing>".

Entry format (copy, newest last):

```
## <protected thing>
Who can access: <user types>
What grants it: <records or conditions>
Where the check lives: <file:function>
Also shown on screen as: <fields used for display only>
Last checked: <YYYY-MM-DD>
```

<!-- Entries start below this line. -->
