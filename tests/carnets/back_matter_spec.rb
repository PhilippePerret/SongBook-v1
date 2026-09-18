# frozen_string_literal: true

require_relative "../spec_helper"
require "carnet_builder"
require "fileutils"

# Issue #104 : pagination pure (sans pdf) de la section "Grilles des accords" — groupes
# lettre -> diagrammes (déjà dédoublonnés/classés par `resolve_back_matter`) répartis en
# pages, chacune une suite de sous-titres/rangées.
RSpec.describe "CarnetBuilder.pack_back_matter_pages" do
  def entries_for(letter, count)
    Array.new(count) { |i| ["#{letter}#{i}", "/fake/#{letter}#{i}-0.svg", nil] }
  end

  it "un seul groupe qui tient sur une page : 1 sous-titre puis les rangées, dans l'ordre" do
    groups = { "A" => entries_for("A", 3) }
    pages = CarnetBuilder.pack_back_matter_pages(groups, 50.0, 70.0, 400.0, 500.0)

    expect(pages.size).to eq(1)
    expect(pages[0].first).to eq({ type: :subtitle, letter: "A" })
    expect(pages[0][1..]).to all(include(type: :row))
  end

  it "plusieurs groupes : un sous-titre par lettre, dans l'ordre des groupes" do
    groups = { "A" => entries_for("A", 2), "C" => entries_for("C", 2) }
    pages = CarnetBuilder.pack_back_matter_pages(groups, 50.0, 70.0, 400.0, 500.0)

    subtitles = pages.flatten.select { |it| it[:type] == :subtitle }.map { |it| it[:letter] }
    expect(subtitles).to eq(%w[A C])
  end

  it "regroupe les diagrammes d'une lettre par rangées de `cols` (largeur/(diag_w+gap_h))" do
    # content_w_pt=250, diag_w=50, gap_h=4 -> cols = floor((250+4)/(50+4)) = 4
    groups = { "A" => entries_for("A", 5) }
    pages = CarnetBuilder.pack_back_matter_pages(groups, 50.0, 70.0, 250.0, 1000.0)

    rows = pages.flatten.select { |it| it[:type] == :row }
    expect(rows.map { |r| r[:paths].size }).to eq([4, 1])
  end

  it "saute une page plutôt que de laisser un sous-titre seul, sans rangée sous lui" do
    # content_h_pt=190 -> top_avail=150 (réserve 40) : le groupe A (sous-titre 24 +
    # 1 rangée 72 = 96) tient, mais il ne reste alors que 54pt -> pas assez pour loger
    # EN PLUS le sous-titre de B suivi d'au moins une rangée (96) -> B démarre une
    # nouvelle page plutôt que de laisser son sous-titre seul en bas de la 1re.
    groups = { "A" => entries_for("A", 1), "B" => entries_for("B", 1) }
    pages = CarnetBuilder.pack_back_matter_pages(groups, 50.0, 70.0, 400.0, 190.0)

    expect(pages.size).to eq(2)
    pages.each do |items|
      subtitle_idx = items.each_index.select { |i| items[i][:type] == :subtitle }
      subtitle_idx.each { |i| expect(items[i + 1] && items[i + 1][:type]).to eq(:row) }
    end
  end

  it "aucun groupe -> une seule page vide (le carnet, lui, n'appelle jamais dans ce cas)" do
    expect(CarnetBuilder.pack_back_matter_pages({}, 50.0, 70.0, 400.0, 500.0)).to eq([[]])
  end
end

# Bout-en-bout (issue #104) : un carnet avec `diags_position: back` et deux cases d'un
# même accord de FORME IDENTIQUE (doigté différent) ne doit produire qu'UN diagramme
# dans les grilles rassemblées — la logique fine (forme/pagination) est déjà couverte
# ci-dessus et dans `chord_diagrams_spec.rb`, ce test-ci vérifie seulement le CÂBLAGE
# (résolution `.schemas`/chemins réels via `CarnetBuilder.build`, jamais de plantage).
RSpec.describe "carnet avec diags_position: back (issue #104)" do
  let(:song_dir) { File.join(FIXTURE_SONGS_DIR, "Test-Back-Dedup") }
  let(:carnet_dir) { File.join(FIXTURE_SONGBOOKS_DIR, "Carnet-Back-Dedup-Test") }

  before do
    FileUtils.mkdir_p(song_dir)
    File.write(File.join(song_dir, "c.lyr"), "{couplet-1}\n/Zz-1:Un /Zz-2:deux\n")
    File.write(File.join(song_dir, "c.infos"), "title: Test Back Dedup\noptions:\n  diags_position: back\n")
    File.write(File.join(song_dir, "c.schemas"), <<~SCH)
      Zz-1 : 1x 2x 30 40 53/2 63/3
      Zz-2 : 1x 2x 30 40 53/1 63/1
    SCH
    %w[Zz-1 Zz-2].each { |c| File.write(File.join(song_dir, "#{c}.svg"), %(<svg viewBox="0 0 60 90"></svg>)) }

    FileUtils.mkdir_p(carnet_dir)
    File.write(File.join(carnet_dir, "c.tdm"), "- Test Back Dedup\n")
    File.write(File.join(carnet_dir, "c.infos"), "title: Carnet Back Dedup Test\n")
  end

  after do
    FileUtils.rm_rf(song_dir)
    FileUtils.rm_rf(carnet_dir)
    FileUtils.rm_rf(File.join(carnet_dir, "export"))
  end

  it "construit sans erreur, une seule page pour les grilles rassemblées (2 cases, 1 seule forme)" do
    out_path = CarnetBuilder.build(carnet_dir)

    expect(File.exist?(out_path)).to be true
    log = File.read(Layout.building_log_path)
    expect(log).to match(%r{grilles des accords rassemblées \(page 1/1\) rendue})
  end
end
