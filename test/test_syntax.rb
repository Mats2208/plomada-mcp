# frozen_string_literal: true

require_relative 'test_helper'

# Every file of the extension compiles. The SketchUp-only files (su/) are not
# loaded by the other tests, so a syntax error there would otherwise only show
# up as "Some Extensions Failed to Load" inside SketchUp.
class TestSyntax < Minitest::Test
  ROOT = File.expand_path('../extension', __dir__)

  def test_every_extension_file_compiles
    files = Dir.glob(File.join(ROOT, '**', '*.rb'))
    assert_operator files.size, :>, 20
    files.each do |f|
      RubyVM::InstructionSequence.compile_file(f)
    rescue SyntaxError => e
      flunk("#{f.sub("#{ROOT}/", '')}: #{e.message.lines.first}")
    end
  end
end
