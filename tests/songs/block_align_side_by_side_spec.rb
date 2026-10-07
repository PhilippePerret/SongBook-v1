# frozen_string_literal: true

require_relative "../spec_helper"
require "carnet_builder"
require "fileutils"

# `block_align: center` sur un bloc de paroles placé à côté d'une tablature (`//`) :
# le bloc est centré sur la PAGE, pas dans la colonne laissée libre par la tablature.
RSpec.describe "block_align: center en côte à côte avec une tablature" do
  # [x gauche, x droit, largeur de la zone] de chaque texte dessiné, du DERNIER document
  # construit (`build_song` construit d'abord un PDF provisoire pour compter les pages).
  def drawn_texts(song_name)
    calls = Hash.new { |h, k| h[k] = [] }
    allow_any_instance_of(Prawn::Document).to receive(:draw_text).and_wrap_original do |m, text, options|
      pdf = m.receiver
      x = options[:at][0]
      calls[pdf.object_id] << [text.to_s, x, x + pdf.width_of(text.to_s, size: options[:size]), pdf.bounds.width]
      m.call(text, options)
    end
    folder = File.join(FIXTURE_SONGS_DIR, song_name)
    begin
      CarnetBuilder.build_song(folder)
    ensure
      FileUtils.rm_rf(File.join(folder, "export"))
    end
    calls.values.last
  end

  it "« Le Sud » : couplet 1 centré sur la page malgré la tablature à sa gauche" do
    texts = drawn_texts("Sud (Le)")
    # Mots dessinés un par un : ligne la plus large = « Qui ressemble à la Louisiane, ».
    _, left, _, area_w = texts.find { |t, *| t == "Qui" }
    _, _, right, = texts.find { |t, *| t == "Louisiane," }
    expect((left + right) / 2.0).to be_within(2).of(area_w / 2.0)
  end
end
