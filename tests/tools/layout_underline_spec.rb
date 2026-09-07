# frozen_string_literal: true

require_relative "../spec_helper"
require "layout"

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
