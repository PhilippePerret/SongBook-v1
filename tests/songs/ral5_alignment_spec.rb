# frozen_string_literal: true

require_relative "../spec_helper"
require "carnet_builder"
require "fileutils"

# RAL5 (Manuel/_dev/regles_esthetiques.adoc) : s'il y a la place sous les strophes de
# la page DROITE, elles DESCENDENT pour que leur 1re ligne de PAROLES soit à la hauteur
# de la 1re ligne de paroles de la page GAUCHE. Vérifié sur le rendu réel : position
# (ligne de base) de chaque texte dessiné, page par page.
RSpec.describe "RAL5 — alignement de la page droite sur la page gauche" do
  # [page (1 = 1re page de la chanson), y de la ligne de base, texte] du DERNIER document
  # construit (`build_song` construit d'abord un PDF provisoire pour compter les pages).
  def drawn_texts(song_name)
    calls = Hash.new { |h, k| h[k] = [] }
    allow_any_instance_of(Prawn::Document).to receive(:draw_text).and_wrap_original do |m, text, options|
      calls[m.receiver.object_id] << [m.receiver.page_number, options[:at][1], text.to_s]
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

  # Ligne de base de la 1re ligne de paroles (la plus HAUTE) contenant `word` sur `page`.
  def first_line_y(texts, page, word)
    ys = texts.select { |p, _, t| p == page && t.include?(word) }.map { |_, y, _| y }
    raise "« #{word} » introuvable page #{page}" if ys.empty?

    ys.max
  end

  it "« The Sound of Silence » : couplets page droite descendus au niveau de « Hello darkness » (texte, pas la ligne d'accords)" do
    texts = drawn_texts("Sound of Silence (The)")
    expect(first_line_y(texts, 2, "Fools")).to be_within(0.5).of(first_line_y(texts, 1, "Hello"))
  end

  it "« Le Plat Pays » : 1re ligne de paroles page droite à la hauteur de celle de la page gauche" do
    texts = drawn_texts("Plat Pays (Le)")
    expect(first_line_y(texts, 2, "Avec")).to be_within(0.5).of(first_line_y(texts, 1, "Avec"))
  end
end
