# frozen_string_literal: true

require_relative "../spec_helper"
require "kdp"

# Tests des outils
RSpec.describe "gabarit imprimeur (KDP)" do
  let(:kdp) { KDP.new(page_count: 100, trim_width: 6, trim_height: 8.25, paper: :white) }

  it "Refuser un nombre de pages trop petit pour être imprimé" do
    petit = KDP.new(page_count: 3, trim_width: 6, trim_height: 8.25)
    expect { petit.gutter_margin }.to raise_error(ArgumentError)
  end

  it "Donner une marge de reliure plus grande pour un livre plus épais" do
    fin = KDP.new(page_count: 100, trim_width: 6, trim_height: 8.25)
    epais = KDP.new(page_count: 600, trim_width: 6, trim_height: 8.25)
    expect(epais.gutter_margin).to be > fin.gutter_margin
  end

  it "Mettre la marge de reliure à gauche sur une page de droite (impaire)" do
    expect(kdp.left_margin(3)).to eq(kdp.gutter_margin)
    expect(kdp.right_margin(3)).to eq(kdp.outside_margin)
  end

  it "Mettre la marge de reliure à droite sur une page de gauche (paire)" do
    expect(kdp.right_margin(4)).to eq(kdp.gutter_margin)
    expect(kdp.left_margin(4)).to eq(kdp.outside_margin)
  end

  it "Un livre avec plus de papier est plus épais (dos plus large)" do
    petit = KDP.new(page_count: 50, trim_width: 6, trim_height: 8.25, paper: :white)
    gros = KDP.new(page_count: 500, trim_width: 6, trim_height: 8.25, paper: :white)
    expect(gros.spine_width).to be > petit.spine_width
  end

  it "Refuser un type de papier inconnu" do
    bizarre = KDP.new(page_count: 100, trim_width: 6, trim_height: 8.25, paper: :licorne)
    expect { bizarre.spine_width }.to raise_error(ArgumentError)
  end

  it "Un point pile au coin de la page n'est pas dans les marges" do
    expect(kdp.inside_margins?(0, 0, page_no: 1)).to be false
  end

  it "Un point bien au centre de la page est dans les marges" do
    expect(kdp.inside_margins?(kdp.trim_width / 2, kdp.trim_height / 2, page_no: 1)).to be true
  end
end
