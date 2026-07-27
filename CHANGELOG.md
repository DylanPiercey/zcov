# zcov

## 0.1.4

### Patch Changes

- 8fc21df: A script read straight off disk now anchors the source column for the same file reached through a bundle, so a branch or function that a remap could only approximate is no longer reported twice, once of them never taken.

## 0.1.3

### Patch Changes

- Remapped functions and branches now land on their own source column rather than wherever the source-map segment began, so a function mapped exactly in one bundle and loosely in another is no longer reported as two, one of which never ran.
