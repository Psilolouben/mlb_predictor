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

LEAGUE_AVG_ERA = 4.20
GMAIL_ADDRESS = 'marky.rigas@gmail.com'.freeze

FunctionsFramework.http "main" do |request|
  handler = request.params['handler'] ?
    Object.const_get("#{request.params['handler']&.split('_')&.collect(&:capitalize)&.join}Handler").new :
    FantasyDataHandler.new

  puts "Using #{handler.class}"

  proposals = []

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

    [[x[:home_team], x[:home], x[:away]], [x[:away_team], x[:away], x[:home]]].each do |team, poss, opp_poss|
      next unless poss > 70

      is_home     = team == x[:home_team]
      pitcher     = is_home ? x[:home_pitcher][:name] : x[:away_pitcher][:name]
      opp_pitcher = is_home ? x[:away_pitcher][:name] : x[:home_pitcher][:name]
      color       = poss > 85 ? "\e[32m" : "\e[33m"
      bar         = ("█" * (poss / 10).round).ljust(10)

      matchup = "#{x[:away_team]} @ #{x[:home_team]}"
      tee.call("#{color}┌#{"─" * 50}┐")
      tee.call("│  %-48s│" % matchup)
      tee.call("│  %-48s│" % "#{team.upcase}  |  #{pitcher} vs #{opp_pitcher}")
      tee.call("│  Win:  #{bar}  #{poss.round(1).to_s.rjust(5)}%#{" " * 23}│")
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
    away_pitcher: match[:away_pitcher][:name]
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

