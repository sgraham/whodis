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

if !exists('g:WhodisHoverAttribute')
  let WhodisHoverAttribute = 'bold'
endif

python <<endpython
import json
import os
import re
import shlex
import subprocess
import vim

WhodisIsOpen = None
WhodisSourceData = None

def _FindCompdbForFile(f):
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


def _LoadCompdb(compdb_path, wanted_path):
  with open(compdb_path, 'rb') as f:
    commands = json.loads(f.read())
  for c in commands:
    path = os.path.normpath(os.path.join(c['directory'], c['file']))
    if path != wanted_path:
      continue
    if 'output' in c:
      output = os.path.normpath(os.path.join(c['directory'], c['output']))
    else:
      split_cmd = shlex.split(c['command'])
      o_file = None
      is_cl = False
      try:
        o_index = split_cmd.index('-o')
        o_file = split_cmd[o_index + 1]
      except ValueError:
        # '-o' not found in split_cmd.
        # Maybe it's cl.exe, look for /Fo instead:
        for part in split_cmd:
          if part.startswith('/Fo'):
            o_file = part[3:]
            is_cl = True
            break
      assert o_file
      output = os.path.normpath(os.path.join(c['directory'], o_file))
    return c['directory'], c['command'], output, is_cl


def _FindIndexForFile(cwd, file_directives, filename):
  for line in file_directives:
    parts = shlex.split(line)
    if len(parts) < 3:
      continue
    index, dirname, basename = parts
    candidate = os.path.normpath(os.path.join(cwd, dirname, basename))
    if candidate == filename:
      return index
  raise ValueError('Could not find TU for ' + filename)


def _FindLineContainingCursor(asm_contents, tu_index, line_number):
  prefix = '\t.loc\t' + tu_index + ' ' + str(line_number) + ' '
  for i, line in enumerate(asm_contents):
    if line.startswith(prefix):
      return i


def _FindFunctionStart(asm_contents, start_index):
  i = start_index - 1
  while (not asm_contents[i].startswith('Lfunc_begin') and
         not asm_contents[i].startswith('.Lfunc_begin')):
    i -= 1
  # After Lfunc_begin, try to walk back to actual function symbol.
  i -= 1
  while ':' not in asm_contents[i]:
    i -= 1
  return i


def _FindFunctionEnd(asm_contents, start_index):
  i = start_index + 1
  while (not asm_contents[i].startswith('Lfunc_end') and
         not asm_contents[i].startswith('.Lfunc_end')):
    i += 1
  return i


def _EnsureScratchBufferOpen():
  original_window = vim.current.window
  TEMP_BUFFER_NAME = '__whodis_asm_viewer__'
  def find_in_buffers():
    for b in vim.buffers:
      if b.name.endswith(TEMP_BUFFER_NAME):
        return b
    return None

  def find_in_windows():
    for w in vim.windows:
      if w.buffer.name.endswith(TEMP_BUFFER_NAME):
        return w
    return None

  # Check if a buffer is already created.
  buf = find_in_buffers()
  if buf is None:
    vim.command('vnew ' + TEMP_BUFFER_NAME)
  else:
    # Buffer is already created, check if there's a window.
    win = find_in_windows()
    if win is not None:
      # Jump to it if it exists.
      vim.current.window = win
    else:
      buf = find_in_buffers()
      vim.command('vsplit +buffer' + str(buf.number))
  return (find_in_buffers(),
          vim.current.window,
          original_window)


def _DropMiscDirectives(contents):
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


def _GetFileNameAndLineNumber(file_and_line_with_colons):
  """ '../../stuff.cc:42:3' -> ('../../stuff.cc', '42')
  """
  parts = file_and_line_with_colons.split(':')
  return parts[0], parts[1]


def _GetSourceLine(cwd, file_name, line_number):
  # TODO: Cache contents, maybe.
  with open(os.path.join(cwd, file_name), 'rb') as f:
    return f.readlines()[int(line_number) - 1].rstrip()


class SourceData(object):
  def __init__(self):
    # List of each line in the disassembly.
    self.contents = []

    # Mapping from disassembly line indices (indexing contents) to the colouring
    # group to be used for that line. Note that these indices are 0-based as
    # normal Python, but Vim wants 1-based lines.
    self.disasm_to_colour_group = []

    # Mapping from disassembly line indices (indexing |contents|) to the source
    # line to which it corresponds. Note that these indices are 0-based as
    # normal Python, but Vim wants 1-based lines.
    # (currently unused)
    #self.disasm_to_source_line = []

    # Maps source line numbers to which colouring group to be used.
    self.source_line_to_colour_group = {}

  def _AddLine(self, text, colour, line_number):
    self.contents.append(text)
    self.disasm_to_colour_group.append(colour)
    #self.disasm_to_source_line.append(line_number)
    assert len(self.contents) == len(self.disasm_to_colour_group)
    #assert len(self.contents) == len(self.disasm_to_source_line)


def _BuildSourceData(cwd, contents, tu_index):
  """Takes the lightly filtered disasm and builds a SourceData describing what
  to display, and how to display it.
  """
  sd = SourceData()
  last_line = -1
  colour_counter = 0
  current_colour = -1
  for line in contents:
    if line.startswith('\t.loc\t'):
      comment_start = line.find('#')
      if comment_start == -1:
        comment_start = line.find('//')
      trailing_filename = line[comment_start:].lstrip('#/').lstrip(' ')
      mo = re.match(r'\t\.loc\t(\d+)', line)
      file_name, line_number = _GetFileNameAndLineNumber(trailing_filename)

      if mo and mo.group(1) != tu_index:
        # If the .loc isn't in our file, don't colour it.
        current_colour = -1
      elif line_number in sd.source_line_to_colour_group:
        current_colour = sd.source_line_to_colour_group[line_number]
      else:
        sd.source_line_to_colour_group[line_number] = colour_counter
        current_colour = colour_counter
        colour_counter += 1

      if line_number != last_line:
        suffix = '  // ' + file_name + ':' + line_number
        if line_number != '0':
          sd._AddLine(
              '# ' + _GetSourceLine(cwd, file_name, line_number) + suffix,
              -1, line_number)
        else:
          sd._AddLine('# ' + file_name + ':' + line_number, -1, line_number)
        last_line = line_number
    else:
      if line.startswith('\t.'):
        sd._AddLine(line, -1, -1)
      else:
        sd._AddLine(line, current_colour, last_line)
  return sd


def _AssignOriginalColours(source_data):
  for line_number, group in source_data.source_line_to_colour_group.iteritems():
    if group == -1:
      continue
    vim.command('syntax match WhodisLineGroup' + str(group) +
                ' /\%' + str(line_number) + 'l./ containedin=ALL contained')


def _AssignDisasmColours(source_data):
  for line_index, group in enumerate(source_data.disasm_to_colour_group):
    if group == -1:
      continue
    vim.command('syntax match WhodisLineGroup' + str(group) +
                ' /\%' + str(line_index + 1) + 'l\t.*/')


def _GetDesiredLine(asm_contents, tu_index):
  cursor_line = vim.current.window.cursor[0]
  line_index = _FindLineContainingCursor(asm_contents, tu_index, cursor_line)
  if not line_index:
    # TODO: Maybe something smarter here. [m doesn't work too well,
    # but maybe some sort of parsing out of a current function name  rather than
    # relying on hitting a used line number.
    raise ValueError('Did not find any code for line ' + str(cursor_line))
  return line_index


def _CreateHighlightGroups(source_data, note_group=-1):
  # http://colorbrewer2.org/?type=qualitative&scheme=Set3&n=12
  # Mapped to xterm256 via misc/map_to_xterm256.py.
  colours = [
    ('8dd3c7', 116),
    ('ffffb3', 229),
    ('bebada', 146),
    ('fb8072', 209),
    ('80b1d3', 110),
    ('fdb462', 215),
    ('b3de69', 149),
    ('fccde5', 224),
    ('d9d9d9', 253),
    ('bc80bd', 139),
    ('ccebc5', 188),
    ('ffed6f', 227),
  ]

  attr = vim.vars['WhodisHoverAttribute']
  def make_group(i, guibg, ctermbg):
    vim.command('highlight clear WhodisLineGroup' + str(i))
    # TODO: bold looks better than underline, but requires that the font in use
    # have a bold style, at least on Mac. Maybe an option to select underline
    # instead of bold and/or disable this entirely.
    vim.command('highlight WhodisLineGroup' + str(i) + ' guibg=#' + guibg +
                ' guifg=black ctermbg=' + str(ctermbg) + ' ctermfg=0' +
                (' gui=' + attr + ' cterm=' + attr if note_group == i else ''))
  for line_number, group in source_data.source_line_to_colour_group.iteritems():
    colour_index = group % len(colours)
    make_group(group, colours[colour_index][0], colours[colour_index][1])


def _UpdateSourceHover():
  global WhodisSourceData
  if not WhodisSourceData:
    return

  try:
    cursor_line = vim.current.window.cursor[0]
    colour_group = WhodisSourceData.disasm_to_colour_group[cursor_line - 1]

    right_now_window = vim.current.window
    vim.current.window = WhodisIsOpen[1]
    _CreateHighlightGroups(WhodisSourceData, colour_group)
    vim.current.window = right_now_window
  except:
    print 'internal error: updating source hover'


def Whodis():
  """If not open, looks at current buffer/line and attempts to disasm that
  function and display it in a new buffer. If it is open, closes the old buffer.
  """

  global WhodisIsOpen
  global WhodisSourceData
  if WhodisIsOpen:
    # Restore the syntax highlighting on the original source window we overrode
    # the highlighting on. Save the now-current window because we have to modify
    # to the then-current one to `syn on`.
    right_now_window = vim.current.window
    try:
      vim.current.window = WhodisIsOpen[1]
      vim.command('syn on')
    except vim.error:
      # The window might have been deleted by the user.
      pass
    vim.current.window = right_now_window

    # Destroy the scratch buffer.
    try:
      vim.command('bd! ' + str(WhodisIsOpen[0].number))
    except:
      # The buffer might have already been deleted by the user.
      pass

    # Remove the global that indicates that we were open.
    WhodisIsOpen = None
    WhodisSourceData = None
    return

  name = vim.current.buffer.name
  cwd, command, output, is_cl = _LoadCompdb(_FindCompdbForFile(name), name)

  # Hackity hack to blah.o.S and append -S assuming that'll get us asm.
  # Another way might be to use gobjdump -S, but it seems like not perfect
  # output for what we want to do here.
  temp_asm = os.path.join(cwd, 'whodis.temp.S')
  if is_cl:
    command_to_run = command.replace('/showIncludes', '')
    #command_to_run = command_to_run.replace('-m32', '')
    command_to_run = command_to_run.replace('/Yubuild/precompile.h', '')
    command_to_run = command_to_run.replace('/Fpobj/chrome/test/unit_tests_cc.pch', '')
    command_to_run += ' /FA /Z7 /Fa' + temp_asm  # /FA defaults to intel.
    open('foo.sh', 'w').write(command_to_run);
  else:
    output_to_find = os.path.relpath(output, cwd)
    command_to_run = command.replace(output_to_find, temp_asm) + ' -S -g'
    if '--target=aarch64' not in command_to_run:
      command_to_run += ' -masm=intel'
  subprocess.check_call(shlex.split(command_to_run), cwd=cwd)

  with open(temp_asm, 'rb') as f:
    asm_contents = [x.rstrip() for x in f.readlines()]
  if is_cl:
    file_lines = [x[10:] for x in asm_contents if x.startswith('\t.cv_file\t')]
  else:
    file_lines = [x[7:] for x in asm_contents if x.startswith('\t.file\t')]
  tu_index = _FindIndexForFile(cwd, file_lines, name)

  line_index = _GetDesiredLine(asm_contents, tu_index)

  # Below _GetDesiredLine() which raises if not found.
  function_start = _FindFunctionStart(asm_contents, line_index)
  function_end = _FindFunctionEnd(asm_contents, line_index)

  contents = _DropMiscDirectives(asm_contents[function_start:function_end + 1])

  filter_prog = vim.vars['WhodisFilterProgram']
  if filter_prog:
    p = subprocess.Popen([filter_prog],
                         stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    new_contents = p.communicate('\n'.join(contents))[0].splitlines(False)
    if p.returncode != 0:
      print 'WhodisFilterProgram ' + filter_prog + ' returned non-zero'
    else:
      contents = new_contents

  source_data = _BuildSourceData(cwd, contents, tu_index)

  buf, scratch_window, original_window = _EnsureScratchBufferOpen()
  buf.options['buftype'] = 'nofile'
  buf.options['bufhidden'] = 'hide'
  buf.options['swapfile'] = False
  buf.options['ts'] = 8
  buf.options['modifiable'] = True
  buf.vars['updatetime'] = 500
  buf[:] = source_data.contents
  buf.options['modifiable'] = False
  vim.command('autocmd CursorHold ' + buf.name + ' python _UpdateSourceHover()')

  buf.options['ft'] = 'asm'
  vim.command('syn on')
  _CreateHighlightGroups(source_data)
  _AssignDisasmColours(source_data)
  buf.options['ft'] = ''

  vim.current.window = original_window
  _CreateHighlightGroups(source_data)
  _AssignOriginalColours(source_data)
  vim.command('syn clear cStatement cppStatement cString cCppString')
  vim.command('syn clear cConditional cRepeat cStorageClass cppStorageClass')
  vim.command('syn clear cType cOperator cLabel cppType cppBoolean')
  vim.command('syn clear cConstant cppConstant cBlock')

  vim.current.window = scratch_window

  # Save that we're open (existence), and original windows for fixup.
  WhodisIsOpen = buf, original_window
  WhodisSourceData = source_data
endpython

execute 'map <silent>' . WhodisKey . ' :python Whodis()<cr>'
