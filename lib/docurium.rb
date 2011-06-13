require 'json'
require 'albino'
require 'pp'

class Docurium
  Version = VERSION = '0.0.1'

  attr_accessor :header_dir, :branch, :output_dir, :data

  def initialize(config_file)
    @data = {:files => [], :functions => {}, :globals => {}, :types => {}, :prefix => ''}
    raise "You need to specify a config file" if !config_file
    raise "You need to specify a valid config file" if !valid_config(config_file)
  end

  def valid_config(file)
    return false if !File.file?(file)
    fpath = File.expand_path(file)
    @project_dir = File.dirname(fpath)
    @config_file = File.basename(fpath)
    @options = JSON.parse(File.read(fpath))
    @data[:prefix] = @options['input'] || ''
    @header_dir = File.join(@project_dir, @data[:prefix])
    raise "Not an input directory" if !File.directory?(@header_dir)
    true
  end


  def set_branch(branch)
    @branch = branch
  end

  def set_output_dir(dir)
    @output_dir = dir
  end

  def generate_docs
    puts "generating docs from #{@header_dir}"
    puts "parsing headers"
    parse_headers
    if @branch
      write_branch
    else
      write_dir
    end
  end

  def parse_headers
    # TODO: get_version
    headers.each do |header|
      parse_header(header)
    end
    @data[:groups] = group_functions
    @data[:types] = @data[:types].sort # make it an assoc array
    find_type_usage
  end

  private

  def group_functions
    func = {}
    @data[:functions].each_pair do |key, value|
      if @options['prefix']
        k = key.gsub(@options['prefix'], '')
      else
        k = key
      end
      group, rest = k.split('_', 2)
      next if group.empty?
      if !rest
        group = value[:file].gsub('.h', '').gsub('/', '_')
      end
      func[group] ||= []
      func[group] << key
      func[group].sort!
    end
    misc = []
    func.to_a.sort
  end

  def headers
    h = []
    Dir.chdir(@header_dir) do
      Dir.glob(File.join('**/*.h')).each do |header|
        next if !File.file?(header)
        h << header
      end
    end
    h
  end

  def find_type_usage
    # go through all the functions and see where types are used and returned
    # store them in the types data
    @data[:functions].each do |func, fdata|
      @data[:types].each_with_index do |tdata, i|
        type, typeData = tdata
        @data[:types][i][1][:used] ||= {:returns => [], :needs => []}
        if fdata[:return][:type].index(/#{type}[ ;\)\*]/)
          @data[:types][i][1][:used][:returns] << func
          @data[:types][i][1][:used][:returns].sort!
        end
        if fdata[:argline].index(/#{type}[ ;\)\*]/)
          @data[:types][i][1][:used][:needs] << func
          @data[:types][i][1][:used][:needs].sort!
        end
      end
    end
  end

  def header_content(header_path)
    File.readlines(File.join(@header_dir, header_path))
  end

  def parse_header(filepath)
    lineno = 0
    content = header_content(filepath)

    # look for structs and enums
    in_block = false
    block = ''
    linestart = 0
    tdef, type, name = nil
    content.each do |line|
      lineno += 1
      line = line.strip

      if line[0, 1] == '#' #preprocessor
        if m = /\#define (.*?) (.*)/.match(line)
          @data[:globals][m[1]] = {:value => m[2].strip, :file => filepath, :line => lineno}
        else
          next
        end
      end

      if m = /^(typedef )*(struct|enum) (.*?)(\{|(\w*?);)/.match(line)
        tdef = m[1] # typdef or nil
        type = m[2] # struct or enum
        name = m[3] # name or nil
        linestart = lineno
        name.strip! if name
        tdef.strip! if tdef
        if m[4] == '{'
          # struct or enum
          in_block = true
        else
          # single line, probably typedef
          val = m[4].gsub(';', '').strip
          if !name.empty?
            name = name.gsub('*', '').strip
            @data[:types][name] = {:tdef => tdef, :type => type, :value => val, :file => filepath, :line => lineno}
          end
        end
      elsif m = /\}(.*?);/.match(line)
        if !m[1].strip.empty?
          name = m[1].strip
        end
        name = name.gsub('*', '').strip
        @data[:types][name] = {:block => block, :tdef => tdef, :type => type, :value => val, :file => filepath, :line => linestart, :lineto => lineno}
        in_block = false
        block = ''
      elsif in_block
        block += line + "\n"
      end
    end
    
    in_comment = false
    in_block = false
    current = -1
    data = []
    lineno = 0
    # look for functions
    content.each do |line|
      lineno += 1
      line = line.strip
      next if line.size == 0
      next if line[0, 1] == '#'
      in_block = true if line =~ /\{/
      if m = /(.*?)\/\*(.*?)\*\//.match(line)
        code = m[1]
        comment = m[2]
        current += 1
        data[current] ||= {:comments => clean_comment(comment), :code => [code], :line => lineno}
      elsif m = /(.*?)\/\/(.*?)/.match(line)
        code = m[1]
        comment = m[2]
        current += 1
        data[current] ||= {:comments => clean_comment(comment), :code => [code], :line => lineno}
      else
        if line =~ /\/\*/
          in_comment = true  
          current += 1
        end
        data[current] ||= {:comments => '', :code => [], :line => lineno}
        data[current][:lineto] = lineno
        if in_comment
          data[current][:comments] += clean_comment(line) + "\n"
        else
          data[current][:code] << line
        end
        if (m = /(.*?);$/.match(line)) && (data[current][:code].size > 0) && !in_block
          current += 1
        end
        in_comment = false if line =~ /\*\//
        in_block = false if line =~ /\}/
      end
    end
    data.compact!
    meta  = extract_meta(data)
    funcs = extract_functions(filepath, data)
    @data[:files] << {:file => filepath, :meta => meta, :functions => funcs, :lines => lineno}
  end

  def clean_comment(comment)
    comment = comment.gsub(/^\/\//, '')
    comment = comment.gsub(/^\/\**/, '')
    comment = comment.gsub(/^\**/, '')
    comment = comment.gsub(/^[\w\*]*\//, '')
    comment
  end

  # go through all the comment blocks and extract:
  #  @file, @brief, @defgroup and @ingroup
  def extract_meta(data)
    file, brief, defgroup, ingroup = nil
    data.each do |block|
      block[:comments].each do |comment|
        m = []
        file  = m[1] if m = /@file (.*?)$/.match(comment)
        brief = m[1] if m = /@brief (.*?)$/.match(comment)
        defgroup = m[1] if m = /@defgroup (.*?)$/.match(comment)
        ingroup  = m[1] if m = /@ingroup (.*?)$/.match(comment)
      end
    end
    {:file => file, :brief => brief, :defgroup => defgroup, :ingroup => ingroup}
  end

  def extract_functions(file, data)
    @data[:functions]
    funcs = []
    data.each do |block|
      ignore = false
      code = block[:code].join(" ")
      code = code.gsub(/\{(.*)\}/, '') # strip inline code
      rawComments = block[:comments]
      comments = block[:comments]

      if m = /^(.*?) ([a-z_]+)\((.*)\)/.match(code)
        ret  = m[1].strip
        if r = /\((.*)\)/.match(ret) # strip macro
          ret = r[1]
        end
        fun  = m[2].strip
        origArgs = m[3].strip

        # replace ridiculous syntax
        args = origArgs.gsub(/(\w+) \(\*(.*?)\)\(([^\)]*)\)/) do |m|
          type, name = $1, $2
          cast = $3.gsub(',', '###')
          "#{type}(*)(#{cast}) #{name}" 
        end

        args = args.split(',').map do |arg|
          argarry = arg.split(' ')
          var = argarry.pop
          type = argarry.join(' ').gsub('###', ',') + ' '

          ## split pointers off end of type or beg of name
          var.gsub!('*') do |m|
            type += '*'
            ''
          end
          desc = ''
          comments = comments.gsub(/\@param #{Regexp.escape(var)} ([^@]*)/m) do |m|
            desc = $1.gsub("\n", ' ').gsub("\t", ' ').strip
            ''
          end
          ## TODO: parse comments to extract data about args
          {:type => type.strip, :name => var, :comment => desc}
        end

        return_comment = ''
        comments.gsub!(/\@return ([^@]*)/m) do |m|
          return_comment = $1.gsub("\n", ' ').gsub("\t", ' ').strip
          ''
        end

        comments = strip_block(comments)
        comment_lines = comments.split("\n\n")

        desc = ''
        if comments.size > 0
          desc = comment_lines.shift.split("\n").map { |e| e.strip }.join(' ')
          comments = comment_lines.join("\n\n").strip
        end

        next if fun == 'defined'
        @data[:functions][fun] = {
          :description => desc,
          :return => {:type => ret, :comment => return_comment},
          :args => args,
          :argline => origArgs,
          :file => file,
          :line => block[:line],
          :lineto => block[:lineto],
          :comments => comments,
          :rawComments => rawComments
        }
        funcs << fun
      end
    end
    funcs
  end

  # TODO: rolled this back, want to strip the first few spaces, not everything
  def strip_block(block)
    block.strip
  end

  def write_branch
    puts "Writing to branch #{@branch}"
    puts "Done!"
  end

  def write_dir
    output_dir = @output_dir || 'docs'
    puts "Writing to directory #{output_dir}"
    here = File.expand_path(File.dirname(__FILE__))

    # files
    # modules
    #
    # functions
    # globals (variables, defines, enums, typedefs)
    # data structures
    #
    FileUtils.mkdir_p(output_dir)
    Dir.chdir(output_dir) do
      FileUtils.cp_r(File.join(here, '..', 'site', '.'), '.') 
      versions = ['HEAD']
      project = {
        :versions => versions,
        :github   => 'libgit2/libgit2',
      }
      File.open("project.json", 'w+') do |f|
        f.write(project.to_json)
      end
      File.open("HEAD.json", 'w+') do |f|
        f.write(@data.to_json)
      end
    end
    puts "Done!"
  end
end
