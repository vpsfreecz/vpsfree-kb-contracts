# Render only the Ruby scenario bodies; no machine configuration or VM is built.
let
  test = import ../tests/suite/runtime/standalone.nix {
    testFramework = {
      sourcePath = "/fixture/not-evaluated";
      makeTest = testFn: _args: testFn {
        pkgs = { ruby = "/fixture/ruby"; git = "/fixture/git"; jq = "/fixture/jq"; };
        lib.replaceStrings = builtins.replaceStrings;
        kbStandalone = {
          source = "/fixture/source";
          sourceMetadata = "/fixture/source.json";
          runtimePackage = "/fixture/runtime";
          capturePackage = "/fixture/capture";
        };
      };
    };
  };
in
builtins.mapAttrs (_name: script: script.script) test.testScripts
