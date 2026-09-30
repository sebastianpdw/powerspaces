# Third-Party Notices

Powerspaces is licensed under the GNU General Public License v3.0 (see
[LICENSE](./LICENSE)). It incorporates portions of the following third-party
software, whose original license terms are reproduced below and continue to
apply to those portions.

---

## InstantSpaceSwitcher

The instant-Space-switch technique in `Sources/CSpaceSwitch/CSpaceSwitch.c` and
`Sources/CSpaceSwitch/SpaceSwitchPolicy.c`, the private `CGEvent` field numbers in
`Sources/CSpaceSwitch/EventSerialization.h`, and the macOS 27 IOHID payload layout
in `Sources/CSpaceSwitch/EventSerialization.c` are adapted from
[InstantSpaceSwitcher](https://github.com/jurplel/InstantSpaceSwitcher) by
Benjamin Owad (jurplel), used under the MIT License:

```
MIT License

Copyright (c) 2026 jurplel

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

The macOS 27 reference is upstream's `macos-27` branch at `bf32cf9`, with phase
pacing and gesture-pairing proposals reviewed in upstream PRs #88, #95, and #97.
Powerspaces maintains this code locally; no upstream binary or package is used.
