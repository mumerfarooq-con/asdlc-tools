# Known traps

One short entry per escaped bug or near miss: something that looked safe but
wasn't. The planner reads this file on every `/asdlc:jira-run`, cites any trap
a ticket matches, and follows its rule. Add an entry after each escaped bug;
an agent may draft it, but it is written only once a human confirms it.

Entry format (newest first, ids never reused):

```
## T-<nnn> | <YYYY-MM-DD> | <bug key> (caused by <key>)
Trap: <what looked safe but wasn't>
How to spot it: <what in a ticket or diff should trigger the check>
Rule: <what the planner must do>
Test: <test that now guards it>
```

<!-- Entries start below this line, newest first. -->
