# frozen_string_literal: true

require_relative "../spec_helper"
require "layout"

# `diags_align` (gauche/droite/justifié/centré) : alignement des diagrammes DANS leur
# bloc — INDÉPENDANT de `diags_position` (qui place le bloc lui-même sur la page).
# `Layout.diag_row_gap`/`Layout.diag_row_x` : UNE SEULE formule, réutilisée par
# `draw_diags_row` (colonne Top/Bottom/Front), `draw_diags_grid` (page dédiée) ET la
# grille de fin de chanson (RAD7-10, `paginate_and_draw`) — avant ce fix, cette
# dernière ignorait totalement `align` (bug constaté, Carnet 1 : `diags: align: Left`
# sans effet sur les diags en trop d'une chanson en `diags_position: End`).
RSpec.describe "Layout.diag_row_gap / Layout.diag_row_x" do
  describe ".diag_row_gap" do
    it ":left/:right/:center -> gouttière FIXE (min_h_dist), jamais étirée" do
      gap = Layout.diag_row_gap(:left, 500, 3, 60)
      expect(gap).to eq(Layout.min_h_dist(:diags))
      expect(Layout.diag_row_gap(:right, 500, 3, 60)).to eq(gap)
      expect(Layout.diag_row_gap(:center, 500, 3, 60)).to eq(gap)
    end

    it ":justify -> gouttière étirée pour occuper avail_w" do
      gap = Layout.diag_row_gap(:justify, 500, 3, 60)
      expect(gap).to be > Layout.min_h_dist(:diags)
    end
  end

  describe ".diag_row_x" do
    let(:avail_w) { 500.0 }
    let(:block_w) { 200.0 }
    let(:gap) { 10.0 }

    it ":left -> collé à x0" do
      expect(Layout.diag_row_x(:left, 40.0, avail_w, block_w, gap)).to eq(40.0)
    end

    it ":right -> collé au bord droit (x0 + avail_w - block_w)" do
      expect(Layout.diag_row_x(:right, 40.0, avail_w, block_w, gap)).to eq(40.0 + avail_w - block_w)
    end

    it ":justify -> démarre après une gouttière (x0 + gap)" do
      expect(Layout.diag_row_x(:justify, 40.0, avail_w, block_w, gap)).to eq(40.0 + gap)
    end

    it ":center (ou toute autre valeur) -> centré dans avail_w" do
      expect(Layout.diag_row_x(:center, 40.0, avail_w, block_w, gap)).to eq(40.0 + (avail_w - block_w) / 2.0)
    end
  end
end
