let
  validator = import ../nix/standalone-profile.nix;
  source = builtins.path { path = ../tests/fixtures/runtime-profile; name = "kb-profile-test-source"; };
  revision = "0123456789abcdef0123456789abcdef01234567";
  metadata = {
    schema = 1;
    inherit revision;
    # Synthetic JSON stores an identity string, not a toFile dependency. The
    # record retains the typed source path for actual lock reads and comparison.
    source = builtins.unsafeDiscardStringContext (toString source);
    lock_sha256 = builtins.hashFile "sha256" (source + "/flake.lock");
  };
  record = {
    schema = 1;
    inherit revision source;
    lockSha256 = metadata.lock_sha256;
    sourceMetadata = builtins.toFile "kb-profile-test-metadata.json" (builtins.toJSON metadata);
    runtimePackage = "/nix/store/00000000000000000000000000000000-test-runtime";
    capturePackage = "/nix/store/11111111111111111111111111111111-test-capture";
  };
  accepted = value: (builtins.tryEval (builtins.deepSeq value true)).success;
  validate = value: validator.validate { inherit source; record = value; };
  require = condition: if condition then true else throw "standalone profile regression failed";
in
{
  pathReevaluation = require (validate record == record);
  missingRevision = require (!(accepted (validate (builtins.removeAttrs record [ "revision" ]))));
  wrongRevision = require (!(accepted (validate (record // { revision = "not-a-revision"; }))));
  wrongSource = require (!(accepted (validate (record // { source = "/different-source"; }))));
  wrongLock = require (!(accepted (validate (record // { lockSha256 = "wrong"; }))));
  wrongMetadataRevision = require (!(accepted (validate (record // {
    sourceMetadata = builtins.toFile "kb-profile-test-wrong-metadata.json" (builtins.toJSON (metadata // { revision = "1111111111111111111111111111111111111111"; }));
  }))));
  wrongMetadataSource = require (!(accepted (validate (record // {
    sourceMetadata = builtins.toFile "kb-profile-test-other-source.json" (builtins.toJSON (metadata // { source = "/different-source"; }));
  }))));
  mutablePackage = require (!(accepted (validate (record // { runtimePackage = "/tmp/runtime"; }))));
  missingGitRevision = require (!(accepted (validator.cleanRevision { outPath = source; })));
  dirtyGitRevision = require (!(accepted (validator.cleanRevision { rev = revision; dirtyRev = revision; })));
  cleanGitRevision = require (validator.cleanRevision { rev = revision; outPath = source; } == revision);
}
