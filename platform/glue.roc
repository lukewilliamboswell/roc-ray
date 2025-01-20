platform "not-used"
    requires {} { main : _ }
    exposes []
    packages {}
    imports []
    provides [main_for_host!]

import Effect

## USED TO RE-GENERATE THE GLUE TYPES FOR THE HOST
## ```
## $ roc glue ../roc/crates/glue/src/RustGlue.roc asdf platform/glue.roc
## ```
main_for_host! : {} => Effect.PlatformStateFromHost
main_for_host! = |{}| main
