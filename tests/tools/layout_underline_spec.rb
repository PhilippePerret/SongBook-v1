# frozen_string_literal: true

require_relative "../spec_helper"
require "layout"
require "dsl_parser"

# Issue #73 : `[...]` dans les paroles = syllabe à souligner, crochets jamais affichés.
# Marqueurs asciidoctor `**...**` (gras) et `__...__` (italique) : même principe.
RSpec.describe "Layout.extract_style_ranges" do
  it "sans marqueur : texte inchangé, aucune plage" do
    clean, ranges = Layout.extract_style_ranges("Bonjour")
    expect(clean).to eq("Bonjour")
    expect(ranges).to eq({ underline: [], bold: [], italic: [] })
  end

  it "une syllabe encadrée : crochets retirés, plage sur le texte nettoyé" do
    clean, ranges = Layout.extract_style_ranges("cha[peau]")
    expect(clean).to eq("chapeau")
    expect(ranges[:underline]).to eq([[3, 7]])
  end

  it "plusieurs syllabes encadrées sur la même ligne" do
    clean, ranges = Layout.extract_style_ranges("[Do]mi[no]")
    expect(clean).to eq("Domino")
    expect(ranges[:underline]).to eq([[0, 2], [4, 6]])
  end

  it "**...** : gras, marqueurs retirés" do
    clean, ranges = Layout.extract_style_ranges("mot **important** ici")
    expect(clean).to eq("mot important ici")
    expect(ranges[:bold]).to eq([[4, 13]])
  end

  it "__...__ : italique, marqueurs retirés" do
    clean, ranges = Layout.extract_style_ranges("__Chœurs__ : la la")
    expect(clean).to eq("Chœurs : la la")
    expect(ranges[:italic]).to eq([[0, 6]])
  end

  it "les trois marqueurs combinés sur une même ligne" do
    clean, ranges = Layout.extract_style_ranges("[Do] **mi** __fa__")
    expect(clean).to eq("Do mi fa")
    expect(ranges).to eq({ underline: [[0, 2]], bold: [[3, 5]], italic: [[6, 8]] })
  end
end

RSpec.describe "Layout.extract_style_ranges_across_segments" do
  def seg(text, chord: nil)
    Segment.new(chord: chord, text: text)
  end

  it "reconnaît __..__ même quand un accord coupe son contenu en plusieurs segments" do
    segs = [
      seg("__Au "),
      seg("moins, es-", chord: "Bm"),
      seg("tu heu", chord: "Em"),
      seg("reux ?__", chord: "Bm"),
    ]
    styled = Layout.extract_style_ranges_across_segments(segs)

    clean_texts = styled.map(&:first)
    expect(clean_texts).to eq(["Au ", "moins, es-", "tu heu", "reux ?"])

    # Reconstruit la plage GLOBALE comme le fait `draw_line` (offset cumulé des textes
    # nettoyés) — plusieurs plages CONTIGUËS (une par segment traversé) sont équivalentes
    # à une seule fusionnée pour `style_runs` (union testée point par point, jamais un
    # texte fusionné avant affichage) : on vérifie la COUVERTURE, pas la fusion.
    full_clean = clean_texts.join
    global_italic = []
    offset = 0
    styled.each do |_clean, ranges|
      ranges[:italic].each { |s, e| global_italic << [offset + s, offset + e] }
      offset += _clean.length
    end
    covered = global_italic.sort.flat_map { |s, e| (s...e).to_a }.uniq.sort
    expect(covered).to eq((0...full_clean.length).to_a)
  end

  it "un marqueur intégralement dans un seul segment reste inchangé" do
    segs = [seg("Pas ce "), seg("qu'on veut", chord: nil)]
    segs[1].text = "__qu'on veut__"
    styled = Layout.extract_style_ranges_across_segments(segs)
    expect(styled[0]).to eq(["Pas ce ", { underline: [], bold: [], italic: [] }])
    expect(styled[1]).to eq(["qu'on veut", { underline: [], bold: [], italic: [[0, 10]] }])
  end
end
