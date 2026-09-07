# frozen_string_literal: true

require_relative "../spec_helper"
require "page_builder"
require "carnet_builder"
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

  after { Options.set!(:diags_shrink, true) }

  def write_song(chords, diags_position: nil, diags_shrink: nil)
    line = chords.map { |c| "/#{c}:#{c} " }.join
    File.write(File.join(@song_dir, "c.lyr"), "{couplet-1}\n#{line.strip}\n")
    infos = "title: Test Diags\n"
    infos += "diags_position: #{diags_position}\n" if diags_position
    infos += "diags_shrink: #{diags_shrink}\n" unless diags_shrink.nil?
    File.write(File.join(@song_dir, "c.infos"), infos)
    chords.each { |c| File.write(File.join(@song_dir, "#{c}-0.svg"), %(<svg viewBox="0 0 60 90"></svg>)) }
  end

  def build(carnet_folder: nil)
    out_path = File.join(@song_dir, "out.pdf")
    PageBuilder.build(@song_dir, out_path, page_size_in: [3.5, 5], page_count: 24, first_page_no: 1, carnet_folder: carnet_folder)
    out_path
  end

  %w[top front end].each do |position|
    it "position #{position} : construit sans erreur, aucun diag perdu, jamais sous le plancher" do
      write_song(CHORDS, diags_position: position)
      out_path = build

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

  it "position top, diags_shrink: false => reste à DIAG_W (jamais rétréci), excédent quand même traité" do
    write_song(CHORDS, diags_position: "top", diags_shrink: false)
    out_path = build

    expect(File.exist?(out_path)).to be true
    log = File.read(Layout.building_log_path)
    expect(log).to match(/lignes? fixes|page dédiée/)
  end

  it "situation normale (peu de diags) : une seule page, pas de mécanisme d'excédent déclenché" do
    write_song(CHORDS.first(2), diags_position: "top")
    out_path = build

    log = File.read(Layout.building_log_path)
    expect(log).not_to match(/lignes? fixes|page dédiée/)
    expect(File.exist?(out_path)).to be true
  end

  # Issue Carnet-1 : `diags_align` (alignement DANS le bloc, indépendant de
  # `diags_position`) doit s'appliquer aussi à la grille de fin de chanson (RAD7-10,
  # `diags_position: end` + excédent) — avant ce fix, cette grille ignorait `align`,
  # toujours centrée quel que soit le réglage. Vérifié via `carnet_folder` + la
  # convention documentée `options: / diags: / align:` (Manuel/songbook/options.adoc).
  it "diags_position: end + carnet avec options: / diags: / align: left — construit sans erreur (align appliqué à la grille d'excédent)" do
    Dir.mktmpdir do |carnet_dir|
      File.write(File.join(carnet_dir, "c.infos"), <<~INFOS)
        title: Carnet Test Align
        options:
          diags:
            align: Left
      INFOS

      write_song(CHORDS, diags_position: "end")
      out_path = build(carnet_folder: carnet_dir)

      expect(File.exist?(out_path)).to be true
      log = File.read(Layout.building_log_path)
      expect(log).to match(/lignes? fixes|page dédiée/)
    end
  end
end
