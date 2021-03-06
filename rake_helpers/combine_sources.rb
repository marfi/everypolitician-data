require 'sass'
require_relative '../lib/wikidata_lookup'
require_relative '../lib/matcher'
require_relative '../lib/reconciliation'
require_relative '../lib/remotesource'
require_relative '../lib/source'

class String
  def tidy
    self.gsub(/[[:space:]]+/, ' ').strip
  end
end

namespace :merge_sources do

  task :fetch_missing do
    fetch_missing
  end

  desc "Combine Sources"
  task 'sources/merged.csv' => :fetch_missing do
    combine_sources
  end

  @recreatable = instructions(:sources).find_all { |i| i.key? :create }
  CLOBBER.include FileList.new(@recreatable.map { |i| i[:file] })

  CLEAN.include 'sources/merged.csv'

  # We re-fetch any file that is missing, or, if REBUILD_SOURCE is set,
  # any file that matches that.
  def _should_refetch(file)
    return true unless File.exist?(file)
    return false unless ENV['REBUILD_SOURCE']
    return file.include? ENV['REBUILD_SOURCE']
  end

  def fetch_missing
    @recreatable.each do |i|
      RemoteSource.instantiate(i).regenerate if _should_refetch(i[:file])
    end
  end

  @warnings = Set.new
  def warn_once(str)
    @warnings << str
  end

  def output_warnings(header)
    warn ['', header, @warnings.to_a, '', ''].join("\n") if @warnings.any?
    @warnings = Set.new
  end

  # http://codereview.stackexchange.com/questions/84290/combining-csvs-using-ruby-to-match-headers
  def combine_sources

    # Make sure all instructions have a `type`
    if (no_type = instructions(:sources).find { |src| src[:type].to_s.empty? })
      raise "Missing `type` in #{no_type} file"
    end

    sources = instructions(:sources).map { |s| Source::Base.instantiate(s) }
    all_headers = (%i(id uuid) + sources.map { |s| s.fields }).flatten.uniq

    merged_rows = []

    # First get all the `membership` rows, and either merge or concat
    sources.select(&:is_memberships?).each do |src|
      warn "Add memberships from #{src.filename}".green
      
      incoming_data = src.filtered_table
      id_map = src.id_map

      # If the row has no ID, we'll need something we can treate as one
      # This 'pseudo id' defaults to slugified 'name' 
      # TODO: do this in `filtered_table`
      incoming_data.select { |r| r[:id].to_s.empty? }.each do |row|
        row[:id] = row[:name].downcase.gsub(/\s+/, '_') 
      end

      if merging = src.merge_instructions.first
        reconciler = Reconciler.new(merging)
        raise "Can't reconciler memberships with a Reconciliation file yet" unless reconciler.filename

        if ENV['GENERATE_RECONCILIATION_INTERFACE'] && reconciler.triggered_by?(ENV['GENERATE_RECONCILIATION_INTERFACE'])
          filename = reconciler.generate_interface!(merged_rows, incoming_data.uniq { |r| r[:id] })
          abort "Created #{filename} — please check it and re-run".green 
        end

        pr = reconciler.previously_reconciled
        abort "No reconciliation data. Rerun with GENERATE_RECONCILIATION_INTERFACE=#{reconciler.trigger_name}" if pr.empty?
        pr.each { |r| id_map[r[:id]] = r[:uuid] } 
      end

      incoming_data.each do |row|
        # Assume that incoming data has no useful uuid column
        row[:uuid] = id_map[row[:id]] ||= SecureRandom.uuid
        merged_rows << row.to_hash
      end

      src.write_id_map_file! id_map
    end

    # Then merge with Biographical data files

    sources.select(&:is_bios?).each do |pd|
      warn "Merging with #{pd.filename}".green

      incoming_data = pd.as_table

      abort "No merge instructions for #{pd.filename}" if (approaches = pd.merge_instructions).empty?
      approaches.each_with_index do |merge_instructions, i|
        reconciler = Reconciler.new(merge_instructions)

        if reconciler.filename
          if ENV['GENERATE_RECONCILIATION_INTERFACE'] && reconciler.triggered_by?(ENV['GENERATE_RECONCILIATION_INTERFACE'])
            filename = reconciler.generate_interface!(merged_rows, incoming_data.uniq { |r| r[:id] })
            abort "Created #{filename} — please check it and re-run".green 
          end

          pr = reconciler.previously_reconciled
          abort "No reconciliation data. Rerun with GENERATE_RECONCILIATION_INTERFACE=#{reconciler.trigger_name}" if pr.empty?
          matcher = Matcher::Reconciled.new(merged_rows, merge_instructions, pr)
        else 
          matcher = Matcher::Exact.new(merged_rows, merge_instructions)
        end

        unmatched = []
        incoming_data.each do |incoming_row|

          incoming_row[:identifier__wikidata] ||= incoming_row[:id] if pd.i(:type) == 'wikidata'

          # TODO factor this out to a Patcher again
          to_patch = matcher.find_all(incoming_row)
          if to_patch && !to_patch.size.zero?
            # Be careful to take a copy and not delete from the core list
            to_patch = to_patch.select { |r| r[:term].to_s == incoming_row[:term].to_s } if merge_instructions[:term_match]
            uids = to_patch.map { |r| r[:uuid] }.uniq
            if uids.count > 1
              warn "Error: trying to patch multiple people: #{uids.join('; ')}".red.on_yellow
              next
            end
            to_patch.each do |existing_row|
              # In general, we take the first value we see — other than short dates
              # TODO: have a 'clobber' flag (or list of values to trust the latter source for)
              incoming_row.keys.reject { |h| h == :id }.each do |h|
                next if incoming_row[h].to_s.empty?

                # If we didn't have anything before, take the new version
                if existing_row[h].to_s.empty? || existing_row[h].to_s.downcase == 'unknown'
                  existing_row[h] = incoming_row[h] 
                  next
                end

                # These are _expected_ to be different on a term-by-term basis
                next if %i(term group group_id area area_id).include? h

                # Can't do much yet with these ones…
                next if %i(source given_name family_name).include? h

                # TODO accept multiple values for :image, :website, etc.
                next if %i(image website twitter facebook).include? h

                # If we have the same as before (case insensitively), that's OK
                next if existing_row[h].downcase == incoming_row[h].downcase

                # Accept more precise dates
                if h.to_s.include?('date') 
                  if incoming_row[h].include?(existing_row[h])
                    existing_row[h] = incoming_row[h] 
                    next
                  end
                  # Ignore less precise dates
                  next if existing_row[h].include?(incoming_row[h])
                end

                # Store alternate names for `other_names`
                if h == :name
                  all_headers |= [:alternate_names] 
                  existing_row[:alternate_names] ||= nil
                  existing_row[:alternate_names] = [existing_row[:alternate_names], incoming_row[:name]].compact.join(";")
                  next
                end

                warn_once "  ☁ Mismatch in #{h} for #{existing_row[:uuid]} (#{existing_row[h]}) vs #{incoming_row[h]} (for #{incoming_row[:id]})"
              end

            end
          else
            unmatched << incoming_row
          end
        end

        warn "* %d of %d unmatched".magenta % [unmatched.count, incoming_data.count] if unmatched.any?
        unmatched.sample(10).each do |r|
          warn "\t#{r.to_hash.reject { |k,v| v.to_s.empty? }.select { |k, v| %i(id name).include? k } }"
        end 
        output_warnings("Data Mismatches")
        incoming_data = unmatched
      end
    end

    # Gender information from Gender-Balance.org
    if gb = sources.find { |src| src.type.downcase == 'gender' }
      warn "Adding GenderBalance results from #{gb.filename}".green 

      min_selections = 5   # accept gender if at least this many votes
      vote_threshold = 0.8 # and at least this ratio of votes were for it

      gb_votes = gb.as_table.reject { |r| (r[:total] -= r[:skip]) < min_selections }.group_by { |r| r[:uuid] }
      gb_score = 0
      gb_added = 0

      merged_rows.group_by { |r| r[:uuid] }.select { |id, rs| gb_votes.key? id }.each do |id, rs|
        r = rs.first
        votes = gb_votes[id].first

        # Has something score at least 80% of votes?
        winner = %w(male female other).find { |g| (votes[g.to_sym].to_f / votes[:total].to_f) >= vote_threshold } or begin
          warn "  Unclear gender vote pattern: #{votes.to_hash}"
          next
        end
        gb_score += 1

        # Warn if our results are different from another source
        if r[:gender] && (r[:gender] != winner)
          warn_once "    ☁ Mismatch for #{r[:uuid]} #{r[:name]} (Was: #{r[:gender]} | GB: #{winner})"
          next
        end

        next if r[:gender]
        r[:gender] = winner
        gb_added += 1
      end
      output_warnings("GenderBalance Mismatches")
      warn "  ⚥ data for #{gb_score}; #{gb_added} added\n".cyan 
    end

    # Map Areas
    if area = sources.find { |src| src.type.downcase == 'ocd' }
      warn "Adding OCD areas from #{area.filename}".green
      ocds = area.as_table.group_by { |r| r[:id] }

      if area.generate == 'area'
        merged_rows.each do |r|
          r[:area] = ocds[r[:area_id]].first[:name] rescue nil
        end

      else
        # Generate IDs from names
        # So far only tested with Australia, so super-simple logic.
        # TOOD: Expand this later

        fuzzer = FuzzyMatch.new(ocds.values.flatten(1), read: :name)
        finder = ->(r) { fuzzer.find(r[:area], must_match_at_least_one_word: true) }

        overrides = area.overrides
        override = ->(name) {
          return unless override_id = overrides[name.to_sym]
          return '' if override_id.empty?
          binding.pry
          # FIXME look up in Hash instead
          # ocds.find { |o| o[:id] == override_id } or raise "no match for #{override_id}"
        }

        areas = {}
        merged_rows.each do |r|
          raise "existing Area ID: #{r[:area_id]}" if r.key? :area_id
          unless areas.key? r[:area]
            areas[r[:area]] = override.(r[:area]) || finder.(r)
            if areas[r[:area]].to_s.empty?
              warn "  No area match for #{r[:area]}"
            else
              warn "  Matched Area %s to %s" % [ r[:area].to_s.yellow, areas[r[:area]][:name].to_s.green ] unless areas[r[:area]][:name].include? " #{r[:area]} "
            end
          end
          next if areas[r[:area]].to_s.empty?
          r[:area_id] = areas[r[:area]][:id]
        end
      end
    end

    # Any local corrections in manual/corrections.csv
    # TODO add this as a Source
    corrections_file = 'sources/manual/corrections.csv'
    if File.exist? corrections_file
      warn "Applying local corrections from #{corrections_file}".green
      CSV.table(corrections_file, converters: nil).each do |correction|
        rows = merged_rows.select { |r| r[:uuid] == correction[:uuid] } 
        if rows.empty?
          warn "Can't correct #{correction[:uuid]} — no such person"
          next
        end

        field = correction[:field].to_sym
        rows.each do |row|
          unless row[field] == correction[:old]
            warn "Can't correct #{correction[:uuid]}: #{field} is '#{row[field]} not '#{correction[:old]}'"
            next
          end
          row[field] = correction[:new]
        end
      end
    end


    # TODO add this as a Source
    legacy_id_file = 'sources/manual/legacy-ids.csv'
    if File.exist? legacy_id_file
      legacy = CSV.table(legacy_id_file, converters: nil).reject { |r| r[:legacy].to_s.empty? }.group_by { |r| r[:id] }

      all_headers |= %i(identifier__everypolitician_legacy)

      merged_rows.each do |row|
        if legacy.key? row[:uuid] 
          # TODO: row[:identifier__everypolitician_legacy] = legacy[ row[:uuid ] ].map { |i| i[:legacy] }.join ";"
          row[:identifier__everypolitician_legacy] = legacy[ row[:uuid ] ].first[:legacy] 
        end
      end
    end

    # No matter what 'id' columns we had, use the UUID as the final ID
    merged_rows.each { |row| row[:id] = row[:uuid] }

    # Then write it all out
    CSV.open("sources/merged.csv", "w") do |out|
      out << all_headers
      merged_rows.each { |r| out << all_headers.map { |header| r[header.to_sym] } }
    end

  end

end
