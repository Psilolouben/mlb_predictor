require 'httparty'
require 'pry'
require 'pry-nav'
require 'distribution'
require 'date'
require 'json'
require 'csv'
require "google/cloud/storage"
require 'nokogiri'
require 'selenium-webdriver'
require 'net/smtp'

Dir["./handlers/*.rb"].each {|file| require file }

ODDS_URL = 'https://www.novibet.gr/spt/feed/marketviews/location/v2/4324/4375810'
LEAGUE_AVG_ERA = 4.20
GMAIL_ADDRESS = 'marky.rigas@gmail.com'.freeze

FunctionsFramework.http "main" do |request|
  handler = request.params['handler'] ?
    Object.const_get("#{request.params['handler']&.split('_')&.collect(&:capitalize)&.join}Handler").new :
    FantasyDataHandler.new

  puts "Using #{handler.class}"

  proposals = []
  #todays_odds = odds.compact

  handler.stats.each do |s|
    next unless s[:home_pitcher][:era] && s[:away_pitcher][:era]

    #puts "Simulating games..."
    res = []
    15000.times do
      res << simulate_match(s).merge(s)
    end
    win_results = res.select { |x| x[:home] != x[:away] }
    a = handler.extract_proposals(res, win_results)
    proposals << a if a
  end

  email_buf = []
  tee = ->(line) { puts line; email_buf << line.gsub(/\e\[[0-9;]*m/, '') }

  tee.call("\n#{"═" * 52}")
  tee.call("  MLB BET PROPOSALS — #{Date.today.strftime("%b %d, %Y")}")
  tee.call("#{"═" * 52}\n")

  proposals.each do |x|
    next if x[:home_pitcher][:era_warning] || x[:away_pitcher][:era_warning]

    [[x[:home_team], x[:home], x[:away], x[:home_odd]], [x[:away_team], x[:away], x[:home], x[:away_odd]]].each do |team, poss, opp_poss, odd|
      next unless poss > 70

      is_home     = team == x[:home_team]
      pitcher     = is_home ? x[:home_pitcher][:name] : x[:away_pitcher][:name]
      opp_pitcher = is_home ? x[:away_pitcher][:name] : x[:home_pitcher][:name]
      color       = poss > 85 ? "\e[32m" : "\e[33m"
      bar         = ("█" * (poss / 10).round).ljust(10)

      sim_prob    = poss / 100.0
      imp_prob    = odd ? (1.0 / odd) : nil
      edge        = imp_prob ? ((sim_prob - imp_prob) * 100).round(1) : nil
      kelly       = (edge && edge > 0 && odd) ? ((edge / 100.0) / (odd - 1) * 100).round(1) : nil
      tag         = if edge && edge.abs >= 10
                      edge > 0 ? " \e[0m\e[1m\e[32m[EDGE]\e[0m#{color}" : " \e[0m\e[1m\e[31m[FADE]\e[0m#{color}"
                    else
                      ""
                    end

      matchup = "#{x[:away_team]} @ #{x[:home_team]}"
      tee.call("#{color}┌#{"─" * 50}┐")
      tee.call("│  %-48s│" % matchup)
      tee.call("│  %-48s│" % "#{team.upcase}  |  #{pitcher} vs #{opp_pitcher}")
      tee.call("│  Win:  #{bar}  #{poss.round(1).to_s.rjust(5)}%#{tag}#{" " * (tag.empty? ? 23 : 7)}│")
      if odd
        imp_str  = "imp #{(imp_prob * 100).round(1)}%"
        edge_str = edge >= 0 ? "edge +#{edge}%" : "edge #{edge}%"
        kelly_str = kelly ? "  kelly #{kelly}%" : ""
        tee.call("│  Odds: #{format('%.2f', odd)}  #{imp_str}  #{edge_str}#{kelly_str}#{" " * [0, 48 - (8 + imp_str.length + 2 + edge_str.length + kelly_str.length)].max}│")
      end
      tee.call("│  Runs: O7.5 #{x[:o75].round(1).to_s.rjust(5)}%  O8.5 #{x[:o85].round(1).to_s.rjust(5)}%  O9.5 #{x[:o95].round(1).to_s.rjust(5)}%#{" " * 4}│")
      tee.call("│  Avg total runs: %-31s│" % "#{x[:avg_total_runs].round(2)}  (#{x[:most_possible_runs_home]}-#{x[:most_possible_runs_away]} most likely)")
      tee.call("└#{"─" * 50}┘\n")
    end
  end;0

  send_proposals_email(email_buf.join("\n")) unless email_buf.empty?

  handler.export_to_csv(proposals)
  "CSV file here -> #{handler.upload_to_bucket}"
end

def simulate_match(match)
  expected_home_era = Distribution::Normal.rng(match[:home_pitcher][:era]).call
  expected_away_era = Distribution::Normal.rng(match[:away_pitcher][:era]).call
  away_k_rate = match[:away_pitcher][:k_rate] || 0
  home_k_rate = match[:home_pitcher][:k_rate] || 0
  home_runs = match[:home_avg_rbi].map { |x| rand < away_k_rate ? 0 : Distribution::Poisson.rng(x) }.sum
  away_runs = match[:away_avg_rbi].map { |x| rand < home_k_rate ? 0 : Distribution::Poisson.rng(x) }.sum

  {
    home_team: match[:home_team],
    away_team: match[:away_team],
    home: [home_runs * (expected_away_era / LEAGUE_AVG_ERA), 0].max,
    away: [away_runs * (expected_home_era / LEAGUE_AVG_ERA), 0].max,
    home_pitcher: match[:home_pitcher][:name],
    away_pitcher: match[:away_pitcher][:name],
    home_odd: match[:home_odd],
    away_odd: match[:away_odd]
  }
end

def send_proposals_email(body)
  password = ENV['GMAIL_APP_PASSWORD']
  unless password
    puts "GMAIL_APP_PASSWORD env var not set — skipping email"
    return
  end

  date_str = Date.today.strftime('%Y-%m-%d')
  message = <<~MSG
    From: MLB Predictor <#{GMAIL_ADDRESS}>
    To: #{GMAIL_ADDRESS}
    Subject: Bet proposals #{date_str}
    Content-Type: text/plain; charset=UTF-8

    #{body}
  MSG

  smtp = Net::SMTP.new('smtp.gmail.com', 587)
  smtp.enable_starttls
  smtp.start('localhost', GMAIL_ADDRESS, password, :login) do |s|
    s.send_message(message, GMAIL_ADDRESS, GMAIL_ADDRESS)
  end
  puts "Email sent to #{GMAIL_ADDRESS}"
rescue => e
  puts "Email failed: #{e.message}"
end

def odds
  odds = HTTParty.get(ODDS_URL, timeout: 120)
  odds.first['betViews'].first['items'].map do |odd|
    next if odd['isLive']

    {
      home: odd['additionalCaptions']['competitor1'].split('(').first.split(' ').first,
      away: odd['additionalCaptions']['competitor2'].split('(').first.split(' ').first,
      home_odd: odd['markets'].first&.dig('betItems')&.first&.dig('price'),
      away_odd: odd['markets'].first&.dig('betItems')&.last&.dig('price')
    }
  end
end
