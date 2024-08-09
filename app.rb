require 'httparty'
require 'pry'
require 'pry-nav'
require 'distribution'
require 'date'
require 'json'
require 'csv'
require "google/cloud/storage"
require 'nokogiri'
require_relative 'handlers/fantasy_data_handler.rb'

#GAMES_URL = 'https://fantasydata.com/MLB_Lineups/RefreshLineups'
GAMES_URL = "https://fantasydata.com/mlb/daily-lineups?date=#{Date.today.to_s}"
ODDS_URL = 'https://www.novibet.gr/spt/feed/marketviews/location/v2/4324/4375810'

FunctionsFramework.http "main" do |request|
  handler = FantasyDataHandler.new

  proposals = []
  todays_odds = odds.compact

  handler.stats.each do |s|
    next unless s[:home_pitcher][:era] && s[:away_pitcher][:era]

    puts "Simulating games..."
    res = []
    15000.times do
      res << simulate_match(s).merge(s)
    end
    final_results = res.select{ |x| x[:home] != x[:away]}
    a = handler.extract_proposals(final_results)
    pp a
    proposals << a
  end
  handler.export_to_csv(proposals)
  "CSV file here -> #{handler.upload_to_bucket}"
end

def simulate_match(match)
  expected_home_era = Distribution::Normal.rng(match[:home_pitcher][:era]).call
  expected_away_era = Distribution::Normal.rng(match[:away_pitcher][:era]).call
  home_runs =  match[:home_avg_rbi].map { |x| Distribution::Poisson.rng(x) }.sum
  away_runs =  match[:away_avg_rbi].map { |x| Distribution::Poisson.rng(x) }.sum

  {
    home_team: match[:home_team],
    away_team: match[:away_team],
    home: (home_runs + expected_away_era) / 2,
    away: (away_runs + expected_home_era) / 2,
    home_pitcher: match[:home_pitcher][:name],
    away_pitcher: match[:away_pitcher][:name],
    home_odd: match[:home_odd],
    away_odd: match[:away_odd]
  }
end

def odds
  odds = HTTParty.get(ODDS_URL, timeout: 120)
  odds.first['betViews'].first['items'].map do |odd|
    next if odd['isLive']
    {
      home: odd['additionalCaptions']['competitor1'].split('(').first.split(' ').first,
      away: odd['additionalCaptions']['competitor2'].split('(').first.split(' ').first,
      home_odd: odd['markets'].first['betItems'].first['price'],
      away_odd: odd['markets'].first['betItems'].last['price']
    }
  end
end
