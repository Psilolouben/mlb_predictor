require_relative './base_handler.rb'
require 'csv'
class BaseballSavantHandler < BaseHandler
  def stats
    lineups.take(2).each_with_object([]) do |l, arr|
      @cached_stats = {}

      puts "Fetching stats for #{l[:home][:name]} - #{l[:away][:name]}..."

      unless l[:home][:pitcher_id] && l[:away][:pitcher_id]
        puts 'Pitcher not found, match will be skipped'
        next
      else
        puts "#{l[:home][:pitcher_name]} vs #{l[:away][:pitcher_name]}"
      end
      binding.pry
      home_pitcher_stats = player_stats(l[:home][:pitcher_id], true)

      arr <<
        {
          home_team: l[:home][:name],
          away_team: l[:away][:name],
          home_pitcher: {
            era: home_pitcher_era,
            name: l[:home][:pitcher_name],
            era_warning: home_pitcher_era&.zero?
            #avg_ko: player_stats(l[:home][:pitcher_id])['Data'].first['PitchingStrikeouts'] / player_stats(l[:home][:pitcher_id])['Data'].first['Games'].to_f
          },
          away_pitcher: {
            era: away_pitcher_era,
            name: l[:away][:pitcher_name],
            era_warning: away_pitcher_era&.zero?
            #avg_ko: player_stats(l[:away][:pitcher_id])['Data'].first['PitchingStrikeouts'] / player_stats(l[:away][:pitcher_id])['Data'].first['Games'].to_f
          },
          home_avg_rbi: l[:home][:player_ids].map { |rb| player_stats(rb)&.children.to_a[10]&.text.to_f / player_stats(rb)&.children.to_a[3]&.text.to_f },
          away_avg_rbi: l[:away][:player_ids].map { |rb| player_stats(rb)&.children.to_a[10]&.text.to_f / player_stats(rb)&.children.to_a[3]&.text.to_f },
          home_odd: nil,
          away_odd: nil
        }
    end
  end

  def player_stats(player_id, pitcher = false)
    @cached_stats[player_id] || begin
      d = HTTParty.get(player_stat_url(player_id, pitcher), timeout: 120)
      binding.pry
      convert_csv_to_json(d.body)

    end
  end

  def lineups
    data_json = HTTParty.get(games_url, headers: { 'Content-Type' => 'application/json' })
    data_json.dig('schedule','dates')&.first['games'].map do |m|
      offense_team_id = data_json.dig('schedule','dates')&.first['games'].first.dig('linescore','offense','team','id')
      home_offense_mapping = offense_team_id == m.dig('teams', 'home', 'team', 'id') ? 'offense' : 'defense'
      away_offense_mapping = offense_team_id == m.dig('teams', 'away', 'team', 'id') ? 'offense' : 'defense'

      {
        id: m['gamePk'],
        home: {
          name: m.dig('teams', 'home', 'team', 'name'),
          pitcher_id: m.dig('teams', 'home', 'probablePitcher', 'id'),
          pitcher_name: m.dig('teams', 'home', 'probablePitcher', 'fullName'),
          player_ids: m.dig('linescore', home_offense_mapping)&.reject{|k, _| ['pitcher', 'batter', 'onDeck', 'inHole', 'team', 'battingOrder'].include?(k) }&.map{|_,v| v['id']},
        },
        away: {
          name: m.dig('teams', 'away', 'team', 'name'),
          pitcher_id: m.dig('teams', 'away', 'probablePitcher', 'id'),
          pitcher_name: m.dig('teams', 'away', 'probablePitcher', 'fullName'),
          player_ids: m.dig('linescore', away_offense_mapping)&.reject{|k, _| ['pitcher', 'batter', 'onDeck', 'inHole', 'team', 'battingOrder'].include?(k) }&.map{|_,v| v['id']},
        }
      }
    end
  end

  def games_url
    "https://baseballsavant.mlb.com/schedule?date=#{Date.today.to_s}"
  end

  def player_stat_url(player_id, pitcher)
    "https://baseballsavant.mlb.com/statcast_search/csv?type=pitcher&player_type=#{pitcher ? 'pitcher' : 'batter'}&year=2024&player_id=#{player_id}"
  end

  def convert_csv_to_json(csv_data)
    csv = CSV.parse(csv_data, headers: true)
    csv.map(&:to_h).to_json
  end
end
