# zcov

## 0.1.3

### Patch Changes

- Remapped functions and branches now land on their own source column rather than wherever the source-map segment began, so a function mapped exactly in one bundle and loosely in another is no longer reported as two, one of which never ran.
