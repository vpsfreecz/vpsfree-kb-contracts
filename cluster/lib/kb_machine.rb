# frozen_string_literal: true

require 'osvm'
require_relative 'kb_disks'

module KbRuntime
  module PreparedDisks
    def bind_preparation(state, artifact)
      @kb_preparation = DiskPreparation.new(state, artifact)
      self
    end

    protected

    def prepare_disks
      disks = config.disks.to_h do |disk|
        unless disk.type == 'file' && disk.create && /\A[a-zA-Z0-9_.-]+\z/.match?(disk.device)
          raise Error, 'portable artifacts require owned relative file disks'
        end
        [disk.device, { 'path' => disk_path(disk.device) }]
      end
      if config.respond_to?(:disk_image)
        disks['root'] = { 'path' => root_disk_path, 'initial_image' => config.disk_image }
      end
      @kb_preparation.prepare(name, disks) do
        # Skip upstream NixosMachine's unconditional root replacement.
        OsVm::Machine.instance_method(:prepare_disks).bind_call(self)
        if disks.key?('root')
          File.open(root_disk_path, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600) do |destination|
            IO.copy_stream(config.disk_image, destination)
            destination.flush
            destination.fsync
          end
        end
        disks.each_value { |disk| File.chmod(0o600, disk.fetch('path')) }
      end
    end
  end

  class NixosMachine < OsVm::NixosMachine
    include PreparedDisks
  end

  class VpsadminosMachine < OsVm::VpsadminosMachine
    include PreparedDisks
  end
end
