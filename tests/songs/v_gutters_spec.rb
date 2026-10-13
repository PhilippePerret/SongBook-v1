# frozen_string_literal: true

require_relative "../spec_helper"
require "layout"

# Sous un bandeau (`:band_strophe`), la 1re gouttière vaut toujours la 2e + 4pt — et
# l'ensemble (blocs + gouttières) ne doit JAMAIS dépasser la place disponible quand la
# pagination a jugé que les blocs tenaient aux distances minimales.
RSpec.describe "Layout.distribute_v_gutters sous bandeau" do
  it "« While my Guitar Gently Weeps » p.1 : rien ne dépasse la place disponible" do
    avail = 352.94
    sizes = [10.91, 69.91, 93.91, 38.82, 51.82]
    gutters = Layout.distribute_v_gutters(avail, sizes, top_type: :band_strophe)
    expect(sizes.sum + gutters.sum).to be <= avail + 0.01
    expect(gutters[0]).to be_within(0.01).of(gutters[1] + Layout::BAND_STROPHE_TOP_EXTRA)
    expect(gutters[1..]).to all(be >= Layout.min_v_dist(:default) - 0.01)
  end
end
