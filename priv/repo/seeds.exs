if Mix.env() == :prod do
  raise "demo factories are unavailable in production; use an explicit production bootstrap"
end

Logger.configure(level: :warning)

summary = Clubeira.Seeds.run!()

IO.puts("""
Clubeira #{summary.profile} seed ready:
  #{summary.cities} cities, #{summary.polos} polos
  #{summary.organizations} organizations, #{summary.brands} brands
  #{summary.places} places, #{summary.place_profiles} public profiles
  #{summary.place_categories} curated categories, #{summary.editions} editions
  #{summary.benefit_offers} benefit offers
  #{summary.subscriptions} subscriptions, #{summary.vouchers} voucher allocations
  demo member: #{summary.member_email}
  demo moderator: #{summary.moderator_email}
  demo admin: #{summary.admin_email}
  Mercado Pago webhook account: #{summary.merchant_account_id}
""")
