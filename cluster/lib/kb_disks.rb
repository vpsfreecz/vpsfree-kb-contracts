# frozen_string_literal: true

require_relative 'kb_state'

module KbRuntime
  class DiskPreparation
    def initialize(state, artifact)
      @state, @artifact = state, artifact
    end

    def path(machine)
      @state.path("disks-#{machine}.json")
    end

    def identity(filename)
      stat = File.lstat(filename)
      raise Error, 'retained disk is not an owned private ordinary file' unless stat.file? && stat.uid == Process.uid && stat.size.positive? && (stat.mode & 0o777) == 0o600
      { 'path' => filename, 'device' => stat.dev, 'inode' => stat.ino, 'size' => stat.size }
    end

    def validate(machine)
      record = @state.read(path(machine))
      unless record['schema'] == 1 && record['complete'] == true && record['instance_id'] == @artifact['instance_id'] &&
             record['layout'] == @artifact.fetch('layout').fetch(machine)
        raise Error, 'missing, interrupted or incompatible disk preparation'
      end
      record.fetch('disks').each_value { |disk| raise Error, 'retained disk identity differs' unless identity(disk.fetch('path')) == disk }
      record
    end

    def prepare(machine, disks)
      if File.exist?(path(machine))
        return validate(machine)
      end
      disks.each_value do |disk|
        raise Error, 'unrecorded retained disk will not be adopted' if File.exist?(disk.fetch('path')) || File.symlink?(disk.fetch('path'))
      end
      record = { 'schema' => 1, 'instance_id' => @artifact.fetch('instance_id'),
        'artifact_id' => @artifact.fetch('artifact_id'), 'layout' => @artifact.fetch('layout').fetch(machine),
        'initial_images' => disks.filter_map { |name, disk| [name, disk['initial_image']] if disk['initial_image'] }.to_h,
        'complete' => false, 'disks' => disks }
      @state.write(path(machine), record, immutable: true)
      yield
      record['disks'] = disks.transform_values { |disk| identity(disk.fetch('path')) }
      record['complete'] = true
      @state.write(path(machine), record)
    end
  end
end
