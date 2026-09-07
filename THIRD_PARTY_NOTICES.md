# Third-party notices

The native SwiftUI components in `Sources/PDFRecorderApp/RareComponents.swift`
adapt Rare UI's **Folder Component** and **Step Player** for this application's
PDF opening and page playback controls. They are SwiftUI ports, not React
components embedded in a web view. No JavaScript runtime or Rare UI dependency
is bundled. The native port adds macOS Reduce Motion support and limits the
visible playback steps for large PDFs.

Upstream: https://github.com/swamimalode07/rare-ui

Source files (reviewed September 7, 2026):

- `components/ui/folder-component.tsx`
- `components/ui/step-player.tsx`

## Rare UI license

MIT License

Copyright (c) 2026 Swami Malode

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
