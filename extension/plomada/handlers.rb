# frozen_string_literal: true

require_relative 'server'
require_relative 'su/kit'
require_relative 'su/builders'
require_relative 'su/build'
require_relative 'su/edit'
require_relative 'su/tools'

module Plomada
  # The wire methods the bridge calls. Reads answer within the tick; jobs run
  # one step per tick inside the transparent operation chain.
  module Handlers
    module_function

    def install(registry)
      install_reads(registry)
      install_jobs(registry)
      registry
    end

    def install_reads(r)
      r.read('model_info') { |p, ctx| SU::Inspect.model_info(ctx.model, p) }
      r.read('list_entities') { |p, ctx| SU::Inspect.list_entities(ctx.model, p) }
      r.read('list_tags') { |_p, ctx| SU::Inspect.list_tags(ctx.model) }
      r.read('list_materials') { |_p, ctx| SU::Inspect.list_materials(ctx.model) }
      r.read('get_plan') { |_p, ctx| SU::PlanReader.read(ctx.model) }
      r.read('capture_view', exclusive: true) { |p, ctx| SU::Capture.capture(ctx.model, p) }
    end

    def install_jobs(r)
      r.job('build_plan') do |p, ctx|
        label = p['label'].is_a?(String) && !p['label'].strip.empty? ? "Plomada: #{p['label'].strip[0, 60]}" : 'Plomada: build plan'
        SU::Build.job(p, ctx, label: label)
      end
      r.job('add_wall') { |p, ctx| SU::Edit.add_wall(p, ctx) }
      r.job('add_opening') { |p, ctx| SU::Edit.add_opening(p, ctx) }
      r.job('move_opening') { |p, ctx| SU::Edit.move_opening(p, ctx) }
      r.job('set_wall_height') { |p, ctx| SU::Edit.set_wall_height(p, ctx) }
      r.job('add_slab') { |p, ctx| SU::Edit.add_slab(p, ctx) }
      r.job('add_roof') { |p, ctx| SU::Edit.add_roof(p, ctx) }
      r.job('set_material') { |p, ctx| SU::Edit.set_material(p, ctx) }
      r.job('create_scene') { |p, ctx| SU::Scenes.create(p, ctx) }
      r.job('export_scene_images') { |p, ctx| SU::Scenes.export_images(p, ctx) }
      r.job('export_model') { |p, ctx| SU::Export.job(p, ctx) }
      r.job('reset_plomada') { |p, ctx| SU::Edit.reset(p, ctx) }
      r.job('undo') { |p, ctx| SU::Edit.undo(p, ctx) }
      r.job('execute_ruby') { |p, ctx| SU::RubyEval.job(p, ctx) }
    end
  end
end
