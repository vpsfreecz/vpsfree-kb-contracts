testFn:
{ testFramework, ... }@args:
let
  upstream = testFramework.makeTest testFn;
  mergedExtraArgs = {
    vpsadminos = testFramework.sourcePath;
  }
  // (args.extraArgs or { });
in
upstream (
  args
  // {
    extraArgs = mergedExtraArgs;
    vpsadminosPath = testFramework.sourcePath;
  }
)
