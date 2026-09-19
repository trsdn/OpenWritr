# Pull Request

## Summary

Describe the problem and what this change does.

## Related issue

Link the issue or decision this change implements.

## Validation

- [ ] `swift build -c release -Xswiftc -warnings-as-errors` and `swift test` succeed locally
- [ ] For audio, hotkey, paste, overlay, or update changes: I ran the built app and checked the affected flow

How the change was verified (the tests cover pure logic only, so say what you tried by hand for UI, audio, hotkey, or update changes):

## Impact

- User or operational risk:
- Security or privacy impact (permissions, network destinations, stored or transmitted data):
- Compatibility or migration impact (macOS versions, saved preferences, update path):

## Documentation

- [ ] README, docs, and changelog are updated where the change is user-visible
