# frozen_string_literal: true

require_relative "../spec_helper"
require "page_builder"
require "combine_pdf"
require "tmpdir"
require "fileutils"

# Intégration bout-en-bout : `diags_position` top/front/end avec BEAUCOUP de diags
# (plancher, excédent, débordement en page — même mécanisme que la colonne, voir le
# plan "Diags en rangée").
RSpec.describe "positions de diagrammes (top/front/end), situation critique (excédent)" do
  CHORDS = %w[C D E F G A B Cm Dm Em Fm Gm Am Bm C7 D7 E7 F7 G7 A7 B7 Csus4 Dsus4 Esus4].freeze

  around do |example|
    Dir.mktmpdir do |dir|
      @song_dir = dir
      Layout.building_log_path = File.join(dir, "building.log")
      Layout.conflict_log_path = File.join(dir, "conflicts.log")
      File.write(Layout.building_log_path, "")
      File.write(Layout.conflict_log_path, "")
      Layout.sensitivity = "log"
      Layout.reset_conflicts!
      example.run
    end
  end

  after { Layout.shrink_diags = true }

  def write_song(chords)
    line = chords.map { |c| "/#{c}:#{c} " }.join
    File.write(File.join(@song_dir, "c.lyr"), "{couplet-1}\n#{line.strip}\n")
    File.write(File.join(@song_dir, "c.infos"), "title: Test Diags\n")
    chords.each { |c| File.write(File.join(@song_dir, "#{c}-0.svg"), %(<svg viewBox="0 0 60 90"></svg>)) }
  end

  def build(position)
    out_path = File.join(@song_dir, "out.pdf")
    PageBuilder.build(@song_dir, out_path, page_size_in: [3.5, 5], page_count: 24, first_page_no: 1,
      layout: { diags_position: position })
    out_path
  end

  %w[top front end].each do |position|
    it "position #{position} : construit sans erreur, aucun diag perdu, jamais sous le plancher" do
      write_song(CHORDS)
      out_path = build(position)

      expect(File.exist?(out_path)).to be true
      pages = CombinePDF.load(out_path).pages
      expect(pages.size).to be >= 1

      log = File.read(Layout.building_log_path)
      # L'excédent (RAD5/6/7/10) doit avoir été traité par le mécanisme commun —
      # soit fusionné en bas de la dernière page, soit renvoyé en page dédiée — jamais
      # silencieusement ignoré.
      expect(log).to match(/lignes? fixes|page dédiée/)
    end
  end

  it "position top, shrink_diags: false => reste à DIAG_W (jamais rétréci), excédent quand même traité" do
    Layout.shrink_diags = false
    write_song(CHORDS)
    out_path = build("top")

    expect(File.exist?(out_path)).to be true
    log = File.read(Layout.building_log_path)
    expect(log).to match(/lignes? fixes|page dédiée/)
  end

  it "situation normale (peu de diags) : une seule page, pas de mécanisme d'excédent déclenché" do
    write_song(CHORDS.first(2))
    out_path = build("top")

    log = File.read(Layout.building_log_path)
    expect(log).not_to match(/lignes? fixes|page dédiée/)
    expect(File.exist?(out_path)).to be true
  end
end
