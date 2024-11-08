platform "not-used"
    requires {} { main : _ }
    exposes []
    packages {}
    imports []
    provides [mainForHost!]

import Effect

## USED TO RE-GENERATE THE GLUE TYPES FOR THE HOST
## ```
## $ roc glue ../roc/crates/glue/src/RustGlue.roc asdf platform/glue.roc
## ```
mainForHost! : {} => Effect.PlatformStateFromHost
mainForHost! = \{} -> main
