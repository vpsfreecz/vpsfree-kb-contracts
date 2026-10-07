let
  revisionValid = value: builtins.isString value && builtins.match "[0-9a-f]{40}" value != null;
  storePath = value: builtins.match "/nix/store/[a-z0-9]{32}-[^/]+" (toString value) != null;
  fail = message: throw "KB standalone test profile: ${message}";
in
{
  cleanRevision = source:
    if source ? rev && revisionValid source.rev && !(source ? dirtyRev) && !(source ? dirtyShortRev)
    then source.rev
    else fail "build standalone-test-config from an exact clean Git-flake revision";

  validate = { source, record }:
    if !builtins.isAttrs record || (record.schema or null) != 1 then
      fail "unsupported kbStandalone schema"
    else if !revisionValid (record.revision or null) then
      fail "a full committed revision is required"
    else if toString (record.source or "") != toString source then
      fail "source differs from the evaluated immutable test source"
    else if (record.lockSha256 or null) != builtins.hashFile "sha256" (source + "/flake.lock") then
      fail "lock digest differs from the evaluated source"
    else if !(storePath (record.sourceMetadata or "")) ||
            !(storePath (record.runtimePackage or "")) || !(storePath (record.capturePackage or "")) then
      fail "metadata and package outputs must be immutable store paths"
    else
      let
        metadata = builtins.fromJSON (builtins.readFile record.sourceMetadata);
      in
      if (metadata.schema or null) != 1 || (metadata.revision or null) != record.revision ||
         (metadata.source or null) != toString source || (metadata.lock_sha256 or null) != record.lockSha256 then
        fail "metadata identity differs from the profile"
      else record;
}
