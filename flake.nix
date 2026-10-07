{
  description = "Reproducible contracts for selected vpsFree.cz KB pages";

  inputs = {
    vpsadmin.url = "github:vpsfreecz/vpsadmin/5d5527a67315c18b595345aa6996d7724c1ed071";
    vpsadmin.inputs.vpsadminos.url = "github:vpsfreecz/vpsadminos/6bdf458fd9105379860234ff33d352e55844f08f";
    vpsadminos.follows = "vpsadmin/vpsadminos";
    vpsfStatus = {
      url = "github:vpsfreecz/vpsf-status/master";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.vpsadmin.follows = "vpsadmin";
      inputs.vpsadminos.follows = "vpsadminos";
    };
    nixpkgs.follows = "vpsadminos/nixpkgs";
    toolsNixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    {
      self,
      nixpkgs,
      toolsNixpkgs,
      vpsadmin,
      vpsadminos,
      vpsfStatus,
      ...
    }:
    let
      system = "x86_64-linux";
      lib = nixpkgs.lib;

      env =
        name: default:
        let
          value = builtins.getEnv name;
        in
        if value == "" then default else value;

      slug = env "VPSADMIN_DEVCLUSTER_SLUG" "kb-captures";
      topology = env "VPSADMIN_DEVCLUSTER_TOPOLOGY" "single";
      networkMode = env "VPSADMIN_DEVCLUSTER_NETWORK" "bridge";
      bridgeHelper = env "VPSADMIN_DEVCLUSTER_BRIDGE_HELPER" "/run/wrappers/bin/qemu-bridge-helper";
      certDir = env "VPSADMIN_DEVCLUSTER_CERT_DIR" (toString ./cluster);
      clusterConfigFile = env "VPSADMIN_DEVCLUSTER_CONFIG_FILE" "";
      sshPubKey = env "VPSADMIN_DEVCLUSTER_SSH_PUBKEY" (toString ./cluster/placeholder-authorized-key.pub);
      vpsadminSourcePath = env "VPSADMIN_DEVCLUSTER_VPSADMIN_SOURCE" vpsadmin.outPath;
      vpsadminosSourcePath = env "VPSADMIN_DEVCLUSTER_VPSADMINOS_SOURCE" vpsadminos.outPath;
      haveapiSourcePath = env "VPSADMIN_DEVCLUSTER_HAVEAPI_SOURCE" "";
      configSourcePath = env "VPSADMIN_DEVCLUSTER_CONFIG_SOURCE" "";
      notificationTemplatesSourcePath = env "VPSADMIN_DEVCLUSTER_NOTIFICATION_TEMPLATES_SOURCE" "";
      webSourcePath = env "VPSADMIN_DEVCLUSTER_WEB_SOURCE" "";
      vpsfStatusSourcePath = env "VPSADMIN_DEVCLUSTER_VPSF_STATUS_SOURCE" "";
      vpsadminGoClientSourcePath = env "VPSADMIN_DEVCLUSTER_VPSADMIN_GO_CLIENT_SOURCE" "";
      telegramSecretsSourcePath = env "VPSADMIN_DEVCLUSTER_TELEGRAM_SECRETS" "";
      telegramEnable = env "VPSADMIN_DEVCLUSTER_TELEGRAM_ENABLE" "0";
      instanceId = env "VPSADMIN_KB_INSTANCE_ID" "";
      captureIdentityFile = env "VPSADMIN_KB_CAPTURE_IDENTITY_FILE" "";

      pkgs = import nixpkgs {
        inherit system;
        overlays = import (vpsadminos.outPath + "/os/overlays") {
          inherit (vpsadminos.inputs) netlinkrb ruby-lxc;
        };
      };
      toolPkgs = import toolsNixpkgs { inherit system; };
      fontConfig = toolPkgs.makeFontsConf {
        fontDirectories = [ toolPkgs.liberation_ttf ];
      };

      clusterTest = import ./cluster/nix/test.nix {
        inherit
          lib
          vpsadmin
          vpsadminos
          vpsfStatus
          slug
          topology
          networkMode
          bridgeHelper
          certDir
          clusterConfigFile
          sshPubKey
          vpsadminSourcePath
          vpsadminosSourcePath
          haveapiSourcePath
          configSourcePath
          notificationTemplatesSourcePath
          webSourcePath
          vpsfStatusSourcePath
          vpsadminGoClientSourcePath
          telegramEnable
          telegramSecretsSourcePath
          instanceId
          captureIdentityFile
          ;
      };

      clusterConfig = import (vpsadminos.outPath + "/tests/make-test.nix") clusterTest {
        inherit system;
        pkgs = nixpkgs.outPath;
        extraArgs = { inherit vpsadminos; };
      };

      ruby = pkgs.ruby_vpsadminos;
      runnerDeps = pkgs.bundlerEnv {
        name = "vpsadmin-kb-capture-runner-deps";
        gemfile = vpsadminos.outPath + "/os/packages/test-runner/Gemfile";
        lockfile = vpsadminos.outPath + "/os/packages/test-runner/Gemfile.lock";
        gemset = vpsadminos.outPath + "/os/packages/test-runner/gemset.nix";
        groups = [ "default" ];
        inherit ruby;
        gemConfig = pkgs.vpsadminosRubyGemConfig;
      };

      runner = pkgs.writeShellScriptBin "vpsadmin-kb-capture-cluster-runner" ''
        export GEM_HOME=${runnerDeps}/${ruby.gemPath}
        export GEM_PATH=${runnerDeps}/${ruby.gemPath}
        export RUBYLIB=${self}/cluster/lib:${vpsadminos.outPath}/test-runner/lib:${vpsadminos.outPath}/osvm/lib:${vpsadminos.outPath}/libosctl/lib

        exec ${ruby}/bin/ruby ${self}/cluster/lib/runner.rb "$@"
      '';

      sourceMetadata = toolPkgs.runCommand "vpsfree-kb-runtime-source.json" { nativeBuildInputs = [ toolPkgs.ruby ]; } ''
        ruby ${self}/cluster/source-metadata.rb ${self} ${lib.escapeShellArg (self.rev or "")} > "$out"
      '';
      runtimeTools = [ toolPkgs.coreutils toolPkgs.git toolPkgs.iputils toolPkgs.nix
        toolPkgs.openssh toolPkgs.openssl toolPkgs.ruby toolPkgs.util-linux ];
      runtimePackage = toolPkgs.writeShellApplication {
        name = "vpsfree-kb-devcluster";
        runtimeInputs = runtimeTools;
        text = ''
          exec ruby ${self}/cluster/launcher.rb \
            --state-root "$PWD/.devcluster/v2" \
            --software-metadata ${sourceMetadata} "$@"
        '';
      };
      capturePackage = toolPkgs.symlinkJoin {
        name = "vpsfree-kb-capture";
        paths = [
          (toolPkgs.writeShellApplication {
            name = "vpsfree-kb-capture";
            runtimeInputs = runtimeTools ++ [ toolPkgs.nodejs toolPkgs.vpsfree-client ];
            text = ''
              export NODE_PATH=${toolPkgs.playwright-test}/lib/node_modules
              export PLAYWRIGHT_BROWSERS_PATH=${toolPkgs.playwright-driver.browsers}
              export FONTCONFIG_FILE=${fontConfig}
              exec node ${self}/runner/package-capture.cjs ${sourceMetadata} "$@"
            '';
          })
          (toolPkgs.writeShellApplication {
            name = "vpsfree-kb-validate";
            runtimeInputs = runtimeTools ++ [ toolPkgs.nodejs ];
            text = ''
              exec ruby ${self}/runner/validate-entry.rb "$PWD" ${sourceMetadata} "$@"
            '';
          })
        ];
      };

      standaloneProfile = import ./nix/standalone-profile.nix;
      standaloneTestConfig = toolPkgs.writeText "vpsfree-kb-standalone-test-config.nix" ''
        {
          kbStandalone = {
            schema = 1;
            revision = ${builtins.toJSON (standaloneProfile.cleanRevision self)};
            source = ${builtins.toJSON (toString self)};
            lockSha256 = ${builtins.toJSON (builtins.hashFile "sha256" ./flake.lock)};
            sourceMetadata = ${builtins.toJSON (toString sourceMetadata)};
            runtimePackage = ${builtins.toJSON (toString runtimePackage)};
            capturePackage = ${builtins.toJSON (toString capturePackage)};
          };
        }
      '';

      # Reuse the Git-filtered flake source. Resolving the checkout as a plain
      # path would also import ignored .devcluster VM disks into the Nix store.
      testRunner = pkgs.writeShellScriptBin "test-runner" ''
        export TEST_RUNNER_REPO_ROOT=${lib.escapeShellArg (builtins.toString self)}
        exec ${vpsadminos.packages.${system}.test-runner}/bin/test-runner "$@"
      '';

      testSuiteArgs = {
        kbStandalone = null;
        inherit
          lib
          vpsadmin
          vpsadminos
          vpsfStatus
          ;
      };

      withTestFrameworkDefaults =
        args:
        args // {
          pkgsPath = args.pkgsPath or nixpkgs.outPath;
          suiteArgs = (args.suiteArgs or testSuiteArgs) // {
            kbStandalone = if (args.testConfig or { }) ? kbStandalone then
              standaloneProfile.validate {
                source = self.outPath;
                record = args.testConfig.kbStandalone;
              }
            else null;
          };
        };
    in
    {
      runtimePlan = clusterConfig.config;
      runtimeRunner = { executable = "${ruby}/bin/ruby"; entrypoint = "${self}/cluster/lib/runner.rb"; };
      packages.${system} = {
        cluster-config = clusterConfig.json;
        inherit runner;
        kb-runtime = runtimePackage;
        capture = capturePackage;
        runtime-source = sourceMetadata;
        standalone-test-config = standaloneTestConfig;
        test-runner = testRunner;
        default = clusterConfig.json;
      };

      apps.${system} = {
        runner = {
          type = "app";
          program = "${runner}/bin/vpsadmin-kb-capture-cluster-runner";
        };
        kb-runtime = { type = "app"; program = "${runtimePackage}/bin/vpsfree-kb-devcluster"; };
        capture = { type = "app"; program = "${capturePackage}/bin/vpsfree-kb-capture"; };
        test-runner = {
          type = "app";
          program = "${testRunner}/bin/test-runner";
        };
        default = self.apps.${system}.runner;
      };

      tests.${system} = vpsadminos.lib.testFramework.mkTests {
        inherit system;
        suiteArgs = testSuiteArgs;
        testsRoot = ./tests;
        pkgsPath = nixpkgs.outPath;
      };

      testsMeta.${system} = vpsadminos.lib.testFramework.mkTestsMeta {
        inherit system;
        suiteArgs = testSuiteArgs;
        testsRoot = ./tests;
        pkgsPath = nixpkgs.outPath;
      };

      lib.testFramework = {
        mkTests = args: vpsadminos.lib.testFramework.mkTests (withTestFrameworkDefaults args);
        mkTestsMeta = args: vpsadminos.lib.testFramework.mkTestsMeta (withTestFrameworkDefaults args);
      };

      devShells.${system}.default = toolPkgs.mkShell {
        packages = with toolPkgs; [
          jq
          nodejs
          openssh
          openssl
          fontconfig
          git
          iputils
          nix
          liberation_ttf
          playwright-test
          procps
          (ruby.withPackages (gems: [ gems.minitest ]))
          shellcheck
          util-linux
          vpsfree-client
        ];

        PLAYWRIGHT_BROWSERS_PATH = "${toolPkgs.playwright-driver.browsers}";
        NODE_PATH = "${toolPkgs.playwright-test}/lib/node_modules";
        FONTCONFIG_FILE = fontConfig;
        VPSADMIN_KB_VPSADMIN_SOURCE = vpsadmin.outPath;
        VPSADMIN_KB_OSVM_SOURCE = vpsadminos.outPath;
        shellHook = ''
          unset RUBYOPT RUBYLIB GEM_HOME GEM_PATH BUNDLE_GEMFILE BUNDLE_PATH BUNDLE_BIN BUNDLE_WITH BUNDLE_WITHOUT
          export GEM_HOME="$(${toolPkgs.ruby}/bin/ruby --disable-gems -rrubygems -e 'print Gem.default_dir')"
          export GEM_PATH="$GEM_HOME"
          export RUBYLIB=${vpsadminos.outPath}/osvm/lib:${vpsadminos.outPath}/test-runner/lib:${vpsadminos.outPath}/libosctl/lib
        '';
      };
    };
}
