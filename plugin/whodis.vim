" Copyright 2018 The Chromium Authors. All rights reserved.
" Use of this source code is governed by a BSD-style license that can be
" found in the LICENSE file.
"
" Scott Graham <scott.whodis@h4ck3r.net>

if !has('python')
  s:ErrMsg('Error: vim with +python required')
  finish
endif

if !exists('g:WhodisKey')
  if has('mac')
    let WhodisKey = '<D-A>'
  else
    let WhodisKey = '<C-S-A>'
  endif
endif

if !exists('g:WhodisFilterProgram')
  let WhodisFilterProgram = ''
endif

python <<endpython
import json
import os
import re
import shlex
import subprocess
import vim

def FindCompdbForFile(f):
  """
  '/Users/scottmg/work/crashpad/crashpad/test/mac/dyld.cc' -> 
  '/Users/scottmg/work/crashpad/crashpad/compile_commands.json'
  """
  if not os.path.isfile(f):
    raise ValueError('Expected file, but ' + f + ' is not')

  original = f
  while True:
    cur_dir = os.path.dirname(f)
    if f == cur_dir:
      raise ValueError(
          'compile_commands.json not found above ' + original + '\n' +
          'Run something like:\n' +
          '  ninja -C out/Release -t compdb cc cxx > compile_commands.json\n'
          'in the source root.\n')
    candidate = os.path.join(cur_dir, 'compile_commands.json')
    if os.path.isfile(candidate):
      return candidate
    f = cur_dir


def LoadCompdb(compdb_path):
  with open(compdb_path, 'rb') as f:
    commands = json.loads(f.read())
  result = {}
  for c in commands:
    path = os.path.normpath(os.path.join(c['directory'], c['file']))
    if 'output' in c:
      output = os.path.normpath(os.path.join(c['directory'], c['output']))
    else:
      split_cmd = shlex.split(c['command'])
      o_index = split_cmd.index('-o')
      assert o_index != -1
      output = os.path.normpath(
          os.path.join(c['directory'], split_cmd[o_index + 1]))
    result[path] = c['directory'], c['command'], output
  return result


def FindIndexForFile(cwd, file_directives, filename):
  for line in file_directives:
    parts = shlex.split(line)
    if len(parts) < 3:
      continue
    index, dirname, basename = parts
    candidate = os.path.normpath(os.path.join(cwd, dirname, basename))
    if candidate == filename:
      return index
  raise ValueError('Could not find TU for ' + filename)


def FindLineContainingCursor(asm_contents, tu_index, line_number):
  prefix = '\t.loc\t' + tu_index + ' ' + str(line_number) + ' '
  for i, line in enumerate(asm_contents):
    if line.startswith(prefix):
      return i


def FindFunctionStart(asm_contents, start_index):
  i = start_index - 1
  while not asm_contents[i].startswith('\t.globl\t'):
    i -= 1
  return i


def FindFunctionEnd(asm_contents, start_index):
  i = start_index + 1
  while not asm_contents[i].startswith('\t.cfi_endproc'):
    i += 1
  return i


def EnsureScratchBufferOpen():
  original_window_index = vim.current.window.number
  TEMP_BUFFER_NAME = '__whodis_asm_viewer__'
  def find_in_buffers():
    for b in vim.buffers:
      if b.name.endswith(TEMP_BUFFER_NAME):
        return b.number
    return -1

  def find_in_windows():
    for w in vim.windows:
      if w.buffer.name.endswith(TEMP_BUFFER_NAME):
        return w.number
    return -1

  # Check if a buffer is already created.
  buf_num = find_in_buffers()
  if buf_num == -1:
    vim.command('vnew ' + TEMP_BUFFER_NAME)
  else:
    # Buffer is already created, check if there's a window.
    win_num = find_in_windows()
    if win_num != -1:
      # Jump to it if it exists.
      vim.command(str(win_num) + 'wincmd w')
    else:
      buf_num = find_in_buffers()
      vim.command('vsplit +buffer' + str(buf_num))
  return (vim.buffers[find_in_buffers()],
          vim.current.window.number,
          original_window_index)


def DropMiscDirectives(contents):
  return [x for x in contents if not x.startswith('\t.cfi') and
                                 not x.startswith('\t.file') and
                                 not x.startswith('\t.p2') and
                                 not x.startswith('\t.globl') and
                                 not x.startswith('\t.type') and
                                 not x.startswith('\t.size') and
                                 not x.startswith('\t.weak_definition') and
                                 not x.startswith('# %bb') and
                                 not x.startswith('##') and
                                 not re.match('[ \t]*#', x) and
                                 not re.match('Lcfi\d+:', x) and
                                 not re.match('\.?Ltmp\d+:', x) and
                                 not re.match('\.?Lfunc', x)]


def GetFileNameAndLineNumber(file_and_line_with_colons):
  """ '../../stuff.cc:42:3' -> ('../../stuff.cc', '42')
  """
  parts = file_and_line_with_colons.split(':')
  return parts[0], parts[1]


def GetSourceLine(cwd, file_name, line_number):
  # TODO: Cache contents, maybe.
  with open(os.path.join(cwd, file_name), 'rb') as f:
    return f.readlines()[int(line_number) - 1].rstrip()


def ReplaceLocWithCode(cwd, contents, tu_index):
  """Adds the original code after a line containing a source line indication.
  Returned lines are tuples of (text, colour ident), and the line->colour map.
  """
  result = []
  last_line = -1
  colour_counter = 0
  colour_mapping = {}
  current_colour = -1
  for line in contents:
    if line.startswith('\t.loc\t'):
      trailing_filename = line[line.find('#'):].lstrip('# ')
      file_name, line_number = GetFileNameAndLineNumber(trailing_filename)

      if line_number in colour_mapping:
        current_colour = colour_mapping[line_number]
      else:
        colour_mapping[line_number] = colour_counter
        current_colour = colour_counter
        colour_counter += 1

      if line_number != last_line:
        suffix = '  // ' + file_name + ':' + line_number
        if line_number != '0':
          result.append(('# ' +
                         GetSourceLine(cwd, file_name, line_number) +
                         suffix,
                        -1))
        else:
          result.append(('# ' + file_name + ':' + line_number, -1))
        last_line = line_number
    else:
      if line.startswith('\t.'):
        result.append((line, -1))
      else:
        result.append((line, current_colour))
  return result, colour_mapping


def AssignOriginalColours(colour_map):
  for line_number, group in colour_map.iteritems():
    if group == -1:
      continue
    group %= 12
    vim.command('syntax match WhodisLineGroup' + str(group) +
                ' /\%' + str(line_number) + 'l./ containedin=ALL contained')


def AssignDisasmColours(contents):
  for line_index, (_, group) in enumerate(contents):
    if group == -1:
      continue
    group %= 12
    vim.command('syntax match WhodisLineGroup' + str(group) +
                ' /\%' + str(line_index + 1) + 'l\t.*/')


def GetDesiredLine(asm_contents, tu_index):
  cursor_line = vim.current.window.cursor[0]
  line_index = FindLineContainingCursor(asm_contents, tu_index, cursor_line)
  if not line_index:
    # TODO: Maybe something smarter here. [m doesn't work too well,
    # but maybe some sort of parsing out of a current function name  rather than
    # relying on hitting a used line number.
    raise ValueError('Did not find any code for line ' + str(cursor_line))
  return line_index


def CreateHighlightGroups():
  # http://colorbrewer2.org/?type=qualitative&scheme=Set3&n=12
  # Mapped to xterm256 via misc/map_to_xterm256.py.
  def group(i, guibg, ctermbg):
    vim.command('highlight WhodisLineGroup' + str(i) + ' guibg=#' + guibg +
                ' guifg=black ctermbg=' + str(ctermbg) + ' ctermfg=0')
  group(0, '8dd3c7', 116)
  group(1, 'ffffb3', 229)
  group(2, 'bebada', 146)
  group(3, 'fb8072', 209)
  group(4, '80b1d3', 110)
  group(5, 'fdb462', 215)
  group(6, 'b3de69', 149)
  group(7, 'fccde5', 224)
  group(8, 'd9d9d9', 253)
  group(9, 'bc80bd', 139)
  group(10, 'ccebc5', 188)
  group(11, 'ffed6f', 227)


def CloseWhodis():
  buf, scratch_window_number, original_window_number = EnsureScratchBufferOpen()
  vim.command(str(scratch_window_number) + 'wincmd w')
  vim.command('bd')
  if scratch_window_number != original_window_number:
    vim.command(str(original_window_number) + 'wincmd w')
  vim.command('syn on')
  vim.command('map <silent> %s :python Whodis()<cr>' % vim.eval('WhodisKey'))


def Whodis():
  name = vim.current.buffer.name
  compdb = LoadCompdb(FindCompdbForFile(name))
  cwd, command, output = compdb[name]

  # Hackity hack to blah.o.S and append -S assuming that'll get us asm.
  # Another way might be to use gobjdump -S, but it seems like not perfect
  # output for what we want to do here.
  output_to_find = os.path.relpath(output, cwd)
  temp_asm = os.path.join(cwd, 'whodis.temp.S')
  command_to_run = command.replace(output_to_find, temp_asm) + \
                  ' -S -g -masm=intel'
  subprocess.check_call(shlex.split(command_to_run), cwd=cwd)

  with open(temp_asm, 'rb') as f:
    asm_contents = [x.rstrip() for x in f.readlines()]
  file_lines = [x[7:] for x in asm_contents if x.startswith('\t.file\t')]
  tu_index = FindIndexForFile(cwd, file_lines, name)

  line_index = GetDesiredLine(asm_contents, tu_index)

  # Below GetDesiredLine() which raises if not found.
  whodis_key = vim.eval('WhodisKey')
  vim.command('map <silent> %s :python CloseWhodis()<cr>' % whodis_key)

  function_start = FindFunctionStart(asm_contents, line_index)
  function_end = FindFunctionEnd(asm_contents, line_index)

  contents = DropMiscDirectives(asm_contents[function_start:function_end + 1])

  filter_prog = vim.eval('WhodisFilterProgram')
  if filter_prog:
    p = subprocess.Popen([filter_prog],
                         stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    contents = p.communicate('\n'.join(contents))[0].splitlines(False)

  contents_and_colours, colour_map = ReplaceLocWithCode(cwd, contents, tu_index)

  buf, scratch_window_number, original_window_number = EnsureScratchBufferOpen()
  buf.options['buftype'] = 'nofile'
  buf.options['bufhidden'] = 'hide'
  buf.options['swapfile'] = False
  buf.options['ts'] = 8
  buf.options['modifiable'] = True
  buf[:] = [x[0] for x in contents_and_colours]
  buf.options['modifiable'] = False
  vim.command('map <silent> <nowait> <buffer> %s :python CloseWhodis()<cr>' %
                  whodis_key)

  buf.options['ft'] = 'asm'
  vim.command('syn on')
  CreateHighlightGroups()
  AssignDisasmColours(contents_and_colours)
  buf.options['ft'] = ''

  vim.command(str(original_window_number) + 'wincmd w')
  CreateHighlightGroups()
  AssignOriginalColours(colour_map)
  vim.command('syn clear cStatement cppStatement cString cCppString')
  vim.command('syn clear cConditional cRepeat cStorageClass cppStorageClass')
  vim.command('syn clear cType cOperator cLabel cppType cppBoolean')
  vim.command('syn clear cConstant cppConstant')

  vim.command(str(scratch_window_number) + 'wincmd w')
endpython

execute 'map <silent>' . WhodisKey . ' :python Whodis()<cr>'
