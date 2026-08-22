# SOAR test suite

50 unit tests covering the collector, the rule engine, and the response action
guards.

```
cd soar/tests
python3 -m unittest discover -s . -p "test_*.py" -v
```

No dependencies. boto3 is replaced with a stub in `base.py`, so the suite runs
on any machine with a Python interpreter and cannot fail because a package index
was unreachable. That matters on a self-hosted runner.

## What is covered

| File | Focus |
|---|---|
| `test_collector.py` | Source detection and parsing. A regression here would silently misclassify events and stop playbooks matching, with no error anywhere. |
| `test_rule_engine.py` | Matching, correlation, and the fail-closed defaults. Also asserts playbook integrity, so a malformed playbook fails the build rather than the runtime. |
| `test_actions.py` | The refusal conditions. For a system permitted to change production on its own, the guards are the safety-critical code and an untested guard is an assumption. |

## What is not covered

The AWS calls themselves. Mocking a cloud provider proves the mock works, not
the system. The end-to-end scripts in `scripts/` exercise the real environment
and assert on real state changes, which is where that confidence comes from.

## A bug these tests found

`process()` in the rule engine read `event["event_id"]` directly in a log line.
The collector always sets that field, so no production event would trigger it,
but a replayed or hand-crafted message would raise a `KeyError` and fail the
entire SQS batch rather than the single bad message. Fixed to use `.get()` with
a fallback.
