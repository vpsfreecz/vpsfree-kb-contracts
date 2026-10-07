{
  pkgs,
  system,
  testFramework,
  suiteArgs ? { },
  configuration ? null,
  testConfig ? { },
}:
let
  nixpkgs = import pkgs { inherit system; };
  testLib = testFramework.makeTestLib {
    inherit
      pkgs
      system
      configuration
      testConfig
      suiteArgs
      ;
    lib = nixpkgs.lib;
    suitePath = ./suite;
  };
in
testLib.makeTests [
  "runtime/standalone"
  "kb/firewall"
  "kb/gre"
  "kb/guix"
  "kb/kvm"
]
