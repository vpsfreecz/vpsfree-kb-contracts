# frozen_string_literal: true

def upsert_capture_infrastructure!(shape, node_locations:, console_url:)
  raise "unsupported capture shape schema #{shape['schema'].inspect}" unless shape['schema'] == 1

  environments = {}
  locations = {}

  shape.fetch('environments').each_with_index do |attrs, env_index|
    environment = Environment.find_or_initialize_by(id: env_index + 1)
    environment.assign_attributes(
      label: attrs.fetch('label'),
      domain: attrs.fetch('domain'),
      description: "Screenshot fixture #{attrs.fetch('label')}",
      maintenance_lock: 0,
      maintenance_lock_reason: nil,
      can_create_vps: attrs.fetch('canCreateVps'),
      can_destroy_vps: attrs.fetch('canDestroyVps'),
      vps_lifetime: attrs.fetch('vpsLifetime'),
      max_vps_count: attrs.fetch('maxVpsCount'),
      user_ip_ownership: attrs.fetch('userIpOwnership')
    )
    environment.save!
    environments[attrs.fetch('key')] = environment
  end

  next_location_id = 1
  shape.fetch('environments').each do |env_attrs|
    environment = environments.fetch(env_attrs.fetch('key'))
    env_attrs.fetch('locations').each do |attrs|
      location = Location.find_or_initialize_by(id: next_location_id)
      location.assign_attributes(
        environment:,
        label: attrs.fetch('label'),
        domain: attrs.fetch('domain'),
        description: "Screenshot fixture #{attrs.fetch('label')}",
        maintenance_lock: 0,
        maintenance_lock_reason: nil,
        remote_console_server: console_url,
        has_ipv6: attrs.fetch('hasIpv6')
      )
      location.save!
      locations[attrs.fetch('key')] = location
      next_location_id += 1
    end
  end

  resources = shape.fetch('resources').to_h do |attrs|
    resource = ClusterResource.find_or_initialize_by(name: attrs.fetch('name'))
    resource.assign_attributes(
      label: attrs.fetch('label'),
      resource_type: attrs.fetch('type'),
      min: attrs.fetch('min'),
      max: attrs.fetch('max'),
      stepsize: attrs.fetch('stepSize')
    )
    resource.free_chain = 'Ip::Free' if attrs.fetch('type') == 'object'
    resource.save!
    [attrs.fetch('name'), resource]
  end

  packages = shape.fetch('packages').to_h do |attrs|
    package = ClusterResourcePackage.find_or_initialize_by(
      environment_id: nil,
      user_id: nil,
      label: attrs.fetch('label')
    )
    package.save!

    expected_resource_ids = attrs.fetch('items').map do |name, value|
      resource = resources.fetch(name)
      item = ClusterResourcePackageItem.find_or_initialize_by(
        cluster_resource_package: package,
        cluster_resource: resource
      )
      item.value = value
      item.save!
      resource.id
    end
    package.cluster_resource_package_items.where.not(
      cluster_resource_id: expected_resource_ids
    ).delete_all
    [attrs.fetch('key'), package]
  end

  environments.each_value do |environment|
    DefaultUserClusterResourcePackage.where(environment:).delete_all
  end
  shape.fetch('environments').each do |attrs|
    DefaultUserClusterResourcePackage.create!(
      environment: environments.fetch(attrs.fetch('key')),
      cluster_resource_package: packages.fetch(attrs.fetch('defaultPackage'))
    )
  end

  node_locations.each do |attrs|
    Node.find(attrs.fetch('id')).update!(location: locations.fetch(attrs.fetch('location')))
  end

  {
    environments:,
    locations:,
    packages:,
    resources:
  }
end

def upsert_capture_users!(shape, infrastructure:, admin:, user_logins:)
  environments = infrastructure.fetch(:environments)
  packages = infrastructure.fetch(:packages)
  resources = infrastructure.fetch(:resources)

  shape.fetch('defaultVpsResources').each do |environment_key, values|
    environment = environments.fetch(environment_key)
    values.each do |resource_name, value|
      record = DefaultObjectClusterResource.find_or_initialize_by(
        environment:,
        class_name: 'Vps',
        cluster_resource: resources.fetch(resource_name)
      )
      record.value = value
      record.save!
    end
  end

  user_logins.each do |login|
    user = User.find_by!(login:)

    shape.fetch('environments').each do |env_attrs|
      environment = environments.fetch(env_attrs.fetch('key'))
      default_package = packages.fetch(env_attrs.fetch('defaultPackage'))
      default_values = default_package.cluster_resource_package_items.to_h do |item|
        [item.cluster_resource_id, item.value]
      end
      headroom = shape.fetch('captureUserResourceHeadroom', {}).fetch(
        env_attrs.fetch('key'),
        {}
      )

      config = EnvironmentUserConfig.find_or_initialize_by(environment:, user:)
      config.assign_attributes(
        can_create_vps: env_attrs.fetch('canCreateVps'),
        can_destroy_vps: env_attrs.fetch('canDestroyVps'),
        vps_lifetime: env_attrs.fetch('vpsLifetime'),
        max_vps_count: env_attrs.fetch('maxVpsCount'),
        default: env_attrs.fetch('key') == 'production'
      )
      config.save!

      personal = ClusterResourcePackage.find_or_initialize_by(environment:, user:)
      personal.label = 'Personal package'
      personal.save!

      resources.each_value do |resource|
        item = ClusterResourcePackageItem.find_or_initialize_by(
          cluster_resource_package: personal,
          cluster_resource: resource
        )
        extra_value = headroom.fetch(resource.name, 0).to_i
        item.value = extra_value
        item.save!

        user_resource = UserClusterResource.find_or_initialize_by(
          user:,
          environment:,
          cluster_resource: resource
        )
        user_resource.value = default_values.fetch(resource.id, 0) + extra_value
        user_resource.save!
      end

      expected_packages = [personal, default_package]
      UserClusterResourcePackage.where(environment:, user:).where.not(
        cluster_resource_package: expected_packages
      ).destroy_all
      expected_packages.each do |package|
        assignment = UserClusterResourcePackage.find_or_initialize_by(
          environment:,
          user:,
          cluster_resource_package: package
        )
        assignment.added_by = admin
        assignment.comment = ''
        assignment.save!
      end
    end
  end
end

def capture_nas_confirmation_state(states)
  return :confirmed if states.length == 4 && states.all? { |state| state == :confirmed }
  return :pending if states.length == 4 && states.all? { |state| state == :confirm_create }

  :drift
end

def validate_capture_nas_dataset!(dataset:, user:, pool:, quota:)
  errors = []
  confirmation_states = [dataset.confirmed]
  errors << "full_name=#{dataset.full_name.inspect}" unless dataset.full_name == 'nas'
  errors << "vps_id=#{dataset.vps_id.inspect}" unless dataset.vps_id.nil?
  errors << "ancestry=#{dataset.ancestry.inspect}" unless dataset.ancestry.nil?
  errors << "object_state=#{dataset.object_state.inspect}" unless dataset.object_state == 'active'
  errors << 'user_editable=false' unless dataset.user_editable?
  errors << 'user_create=false' unless dataset.user_create?
  errors << 'user_destroy=false' unless dataset.user_destroy?

  dips = dataset.dataset_in_pools.includes(pool: { node: { location: :environment } }).to_a
  if dips.length != 1 || dips.first.pool_id != pool.id
    copies = dips.map { |dip| "#{dip.id}:#{dip.pool.label}:#{dip.pool.role}" }
    errors << "copies=#{copies.join(',').presence || 'none'}"
  end

  dip = dips.find { |candidate| candidate.pool_id == pool.id }
  if dip
    errors << "dip_label=#{dip.label.inspect}" unless dip.label == 'nas'
    confirmation_states << dip.confirmed

    properties = dip.dataset_properties.where(name: 'quota').to_a
    if properties.length != 1
      errors << "quota_properties=#{properties.length}"
    else
      property = properties.first
      confirmation_states << property.confirmed
      errors << "quota=#{property.value.inspect}" unless property.value.to_i == quota
      errors << "quota_inherited=#{property.inherited.inspect}" if property.inherited?
    end

    uses = ClusterResourceUse.for_obj(dip).includes(
      user_cluster_resource: %i[user environment cluster_resource]
    ).select do |use|
      use.user_cluster_resource.cluster_resource.name == 'diskspace'
    end
    if uses.length != 1
      errors << "diskspace_uses=#{uses.length}"
    else
      use = uses.first
      resource = use.user_cluster_resource
      confirmation_states << use.confirmed
      errors << "diskspace=#{use.value.inspect}" unless use.value.to_i == quota
      errors << "diskspace_enabled=#{use.enabled.inspect}" unless use.enabled?
      errors << "diskspace_user=#{resource.user.login}" unless resource.user_id == user.id
      if resource.environment_id != pool.node.location.environment_id
        errors << "diskspace_environment=#{resource.environment.label}"
      end
    end
  end

  confirmation_state = capture_nas_confirmation_state(confirmation_states)
  if confirmation_state == :drift
    errors << "confirmation_states=#{confirmation_states.map(&:inspect).join(',')}"
  end

  return dataset if errors.empty?

  raise "capture NAS fixture drift for #{user.login}: #{errors.join('; ')}"
end

def ensure_capture_nas_dataset!(user:, pool:, quota:)
  matches = Dataset.where(
    user:,
    vps_id: nil,
    ancestry: nil,
    name: 'nas'
  ).to_a
  raise "multiple capture NAS datasets found for #{user.login}" if matches.length > 1

  if matches.one?
    return validate_capture_nas_dataset!(
      dataset: matches.first,
      user:,
      pool:,
      quota:
    )
  end

  dataset = Dataset.new(
    name: 'nas',
    user:,
    user_editable: true,
    user_create: true,
    user_destroy: true,
    object_state: :active,
    confirmed: Dataset.confirmed(:confirm_create)
  )
  raise ActiveRecord::RecordInvalid, dataset unless dataset.valid?

  _chain, dips = TransactionChains::Dataset::Create.fire(
    pool,
    nil,
    [dataset],
    {
      properties: { quota: },
      user:,
      label: 'nas'
    }
  )
  dips.last.dataset
end

def upsert_capture_notifications!(user:)
  target_value = 'documentation@example.test'
  target = NotificationTarget.find_or_initialize_by(
    user:,
    action: 'email',
    identity_key: NotificationTarget.identity_key_for('email', 'custom', target_value)
  )
  target.assign_attributes(
    label: 'Documentation e-mail',
    target_kind: 'custom',
    target_value:,
    enabled: true,
    verified_at: target.verified_at || Time.utc(2025, 1, 15, 12, 0)
  )
  target.skip_delivery_method_enabled_validation = true
  target.save!

  receiver = NotificationReceiver.find_or_initialize_by(
    user:,
    label: 'Documentation e-mail'
  )
  receiver.assign_attributes(
    description: 'E-mail receiver used in the notification guide',
    enabled: true,
    mute: false
  )
  receiver.save!

  link = receiver.notification_receiver_targets.find_or_initialize_by(
    notification_target: target
  )
  link.position ||= NotificationReceiver.next_receiver_target_position(receiver)
  link.save!

  office_hours = EventTimeInterval.find_or_initialize_by(
    user:,
    name: 'Office hours'
  )
  office_hours.assign_attributes(
    time_zone: 'Europe/Prague',
    specs: [
      {
        times: [{ start_time: '09:00', end_time: '17:00' }],
        weekdays: [{ start: 'monday', end: 'friday' }]
      },
      {
        times: [{ start_time: '09:00', end_time: '12:00' }],
        weekdays: [{ start: 'saturday', end: 'saturday' }]
      }
    ]
  )
  office_hours.save!

  past_window = EventTimeInterval.find_or_initialize_by(
    user:,
    name: 'Past documentation window'
  )
  past_window.assign_attributes(
    time_zone: 'UTC',
    specs: [{ years: [{ start: 1, end: 1 }] }]
  )
  past_window.save!

  documentation_route = EventRoute.find_or_initialize_by(
    user:,
    label: 'Documentation alerts'
  )
  documentation_route.assign_attributes(
    notification_receiver: receiver,
    event_type: 'vps.incident_report',
    event_type_pattern: nil,
    subject_scope: 'self',
    position: 10,
    enabled: true,
    single_use: false,
    continue: false
  )
  documentation_route.save!
  documentation_route.event_route_time_intervals.where.not(
    event_time_interval: office_hours
  ).delete_all
  assignment = documentation_route.event_route_time_intervals.find_or_initialize_by(
    event_time_interval: office_hours
  )
  assignment.mode = :active
  assignment.save!

  scheduled_route = EventRoute.find_or_initialize_by(
    user:,
    label: 'Scheduled-out documentation route'
  )
  scheduled_route.assign_attributes(
    notification_receiver: receiver,
    event_type: 'user.test_notification',
    event_type_pattern: nil,
    subject_scope: 'self',
    position: 20,
    enabled: true,
    single_use: false,
    continue: false
  )
  scheduled_route.save!
  scheduled_route.event_route_time_intervals.where.not(
    event_time_interval: past_window
  ).delete_all
  assignment = scheduled_route.event_route_time_intervals.find_or_initialize_by(
    event_time_interval: past_window
  )
  assignment.mode = :active
  assignment.save!

  Event.where(
    user:,
    event_type: 'user.test_notification',
    subject: 'Scheduled-out documentation event'
  ).destroy_all
  event = VpsAdmin::API::Events.emit!(
    'user.test_notification',
    user:,
    subject: 'Scheduled-out documentation event',
    payload: { note: 'This delivery is outside its active interval.' }
  )
  unless event.suppressed_routing_state? &&
         event.event_route_matches.sole.time_interval_state == 'inactive'
    raise "scheduled capture event was not suppressed: event=#{event.id} state=#{event.routing_state}"
  end

  event
end
