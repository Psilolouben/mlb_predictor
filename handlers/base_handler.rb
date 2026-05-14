class BaseHandler

  def csv_filename
    "proposals/#{PROPOSAL_DATE.strftime('%Y-%m-%d')}.csv"
  end

  def upload_to_bucket
    storage = Google::Cloud::Storage.new(
      project_id: "mlb-bet-predictor",
      credentials: "mlb-bet-predictor-b83d3bb4dce7.json"
    )
    bucket = storage.bucket("gcf-v2-uploads-944915810467-us-central1")
    a = bucket.create_file(csv_filename, csv_filename, cache_control: 'max-age=0')
    a.public_url
  end

  def extract_pitcher_stat(nodes, label)
    return 0 if nodes.empty?
    idx = nodes.index { |x| x.text == label }
    idx ? nodes[idx + 1].text.to_f : 0
  end

  def export_to_csv(proposals)
    Dir.mkdir('proposals') unless Dir.exist?('proposals')
    CSV.open(csv_filename, "w", col_sep: ';') do |csv|
      csv << ['date', 'home_team', 'away_team', 'home_pitcher', 'away_pitcher',
              'home_pct', 'away_pct', 'o75', 'o85', 'o95', 'both_scored', 'avg_total_runs']
      proposals.each do |game|
        csv << [
          PROPOSAL_DATE.strftime('%Y-%m-%d'),
          game[:home_team],
          game[:away_team],
          game[:home_pitcher][:name],
          game[:away_pitcher][:name],
          game[:home].round(2),
          game[:away].round(2),
          game[:o75].round(2),
          game[:o85].round(2),
          game[:o95].round(2),
          game[:both_scored].round(2),
          game[:avg_total_runs].round(2)
        ]
      end
    end;0
  end

  def extract_proposals(all_results, win_results)
    if win_results.empty?
      puts "Warning: no decisive simulations for #{all_results.first[:home_team]} vs #{all_results.first[:away_team]}, skipping"
      return nil
    end
    {
      home_team: all_results.first[:home_team],
      away_team: all_results.first[:away_team],
      home: (win_results.count { |x| x[:home] > x[:away] } / win_results.count.to_f) * 100,
      away: (win_results.count { |x| x[:home] < x[:away] } / win_results.count.to_f) * 100,
      avg_total_runs: all_results.sum { |x| x[:home] + x[:away] } / all_results.count.to_f,
      home_pitcher: all_results.first[:home_pitcher],
      away_pitcher: all_results.first[:away_pitcher],
      o75: (all_results.count { |x| (x[:home] + x[:away]) > 7.5 } / all_results.count.to_f) * 100,
      o85: (all_results.count { |x| (x[:home] + x[:away]) > 8.5 } / all_results.count.to_f) * 100,
      o95: (all_results.count { |x| (x[:home] + x[:away]) > 9.5 } / all_results.count.to_f) * 100,
      both_scored: (all_results.count { |x| x[:home] > 0 && x[:away] > 0 } / all_results.count.to_f) * 100,
      most_possible_runs_home: all_results.map { |x| x[:home].round }.tally.max_by { |_, v| v }&.first,
      most_possible_runs_away: all_results.map { |x| x[:away].round }.tally.max_by { |_, v| v }&.first
    }
  end
end
