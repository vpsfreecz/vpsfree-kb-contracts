IncidentEscalation.configure do
  rule :oomd do
    labels en: 'VPS memory-pressure incidents', cs: 'Incidenty přetížení paměti VPS'
    templates warning: :vps_memory_pressure_warning,
              stopped: :vps_memory_pressure_stopped

    limits warning: 3, stop: 10
    applies_if do |ctx|
      ctx.report[:codename] == 'oomd' && ctx.source[:kind] == 'node_vps_event' &&
        !ctx.source[:key].nil? && !ctx.source[:node_id].nil? &&
        ctx.source[:node_id] == ctx.vps[:node_id] && %w[restart stop].include?(ctx.source[:action])
    end
  end
end
