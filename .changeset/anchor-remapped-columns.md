---
"zcov": patch
---

A script read straight off disk now anchors the source column for the same file reached through a bundle, so a branch or function that a remap could only approximate is no longer reported twice, once of them never taken.
