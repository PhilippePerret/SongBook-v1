# frozen_string_literal: true

require_relative "../spec_helper"
require "layout"

# Issue #73 : `[...]` dans les paroles = syllabe à souligner, crochets jamais affichés.
RSpec.describe "Layout.extract_underline_ranges" do
  it "sans crochet : texte inchangé, aucune plage" do
    clean, ranges = Layout.extract_underline_ranges("Bonjour")
    expect(clean).to eq("Bonjour")
    expect(ranges).to eq([])
  end

  it "une syllabe encadrée : crochets retirés, plage sur le texte nettoyé" do
    clean, ranges = Layout.extract_underline_ranges("cha[peau]")
    expect(clean).to eq("chapeau")
    expect(ranges).to eq([[3, 7]])
  end

  it "plusieurs syllabes encadrées sur la même ligne" do
    clean, ranges = Layout.extract_underline_ranges("[Do]mi[no]")
    expect(clean).to eq("Domino")
    expect(ranges).to eq([[0, 2], [4, 6]])
  end
end
