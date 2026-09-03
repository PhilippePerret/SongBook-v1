# frozen_string_literal: true

require_relative "../spec_helper"
require "layout"

# `diag_row_width` (rangée Top/Bot/Front/End) : plancher `MIN_SIZE[:diags][:width]`,
# jamais franchi (bug initial : 30 diags compressés jusqu'à devenir illisibles).
RSpec.describe "largeur de rangée de diagrammes (diag_row_width)" do
  after { Options.set!(:shrink_diags, true) }

  it "situation normale (tous tiennent à DIAG_W) : largeur inchangée, aucun excédent" do
    w, n_fit = Layout.diag_row_width(Array.new(3), 400)
    expect(w).to eq(Layout::DIAG_W)
    expect(n_fit).to eq(3)
  end

  it "situation critique, shrink_diags: true => rétrécit sous DIAG_W, jamais sous le plancher, tous tiennent" do
    Options.set!(:shrink_diags, true)
    w, n_fit = Layout.diag_row_width(Array.new(6), 320)
    expect(w).to be < Layout::DIAG_W
    expect(w).to be >= Layout::MIN_SIZE[:diags][:width]
    expect(n_fit).to eq(6)
  end

  it "situation critique, shrink_diags: false => reste à DIAG_W, excédent détecté" do
    Options.set!(:shrink_diags, false)
    w, n_fit = Layout.diag_row_width(Array.new(6), 200)
    expect(w).to eq(Layout::DIAG_W)
    expect(n_fit).to be < 6
  end

  it "30 diags : la largeur finale ne descend jamais sous le plancher (bug initial impossible)" do
    Options.set!(:shrink_diags, true)
    w, = Layout.diag_row_width(Array.new(30), 400)
    expect(w).to be >= Layout::MIN_SIZE[:diags][:width]
  end

  it "aucun diag : largeur nominale, rien qui tient" do
    expect(Layout.diag_row_width([], 400)).to eq([Layout::DIAG_W, 0])
  end
end
