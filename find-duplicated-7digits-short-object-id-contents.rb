object_ids = {}
content = "a"
loop do
  object_id = `echo '#{content}' | git hash-object --stdin`.strip
  short_object_id = object_id[0, 7]
  if object_ids.has_key?(short_object_id)
    puts "Found!: '#{object_ids[short_object_id]}':'#{content}'"
    exit
  end
  object_ids[short_object_id] = content
  content = content.succ
  puts object_ids.size if (object_ids.size % 1000).zero?
end
