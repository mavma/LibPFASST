"""Fabric (fabfile.org) tasks for mpi-ndarray."""

import numpy as np

from fabric.api import *
from jobtools import JobQueue, Job
from itertools import product
from collections import defaultdict

nnodes = defaultdict(lambda: [ 5, 3, 2 ], { 
  'ks': [ 9, 5, 3 ]
})

nvars  = defaultdict(lambda: [ 512, 256, 128 ], { 
  'ks': [ 1024, 512, 256 ] 
})

niters = {
  'heat':    defaultdict(lambda: 8, { 1: 12 }),
  'burgers': defaultdict(lambda: 8, { 1: 12 }),
  'ks':      defaultdict(lambda: 8, { 1: 12 }),
}

sigma = defaultdict(lambda: 0.004, { 
  'wave': 0.001 
})

dt = defaultdict(lambda: 0.01, { 
  'wave': 0.5/512,
  'ks':   1.0,
})


@task
def speed():
  """Speedup/timing tests."""

  setenv()

  jobs = JobQueue(rwd=env.scratch + 'speed', queue='regular')

  for prob, nprocs, nlevs in product( [ 'heat', 'burgers', 'ks' ],
                                     [ 1, 4, 8, 16, 32, 64 ],
                                     [ 2, 3 ]):

    name = '%sp%02dl%d' % (prob, nprocs, nlevs)
    job = Job(name=name, 
              param_file='probin.nml.in', 
              rwd=name, 
              width=nprocs, 
              walltime="00:10:00")

    job.update_params(
      problem=prob, output="", nsteps=64, dt=dt[prob], nlevs=nlevs,
      nnodes=nnodes[prob][:nlevs][::-1], nvars=nvars[prob][:nlevs][::-1],
      niters=niters[prob][nprocs], nu=0.005, sigma=0.004,
      )

    jobs.add(job)

  jobs.submit_all()


@task
def flamebox_speed_comp():
  """Compute convergence errors (run speed-comp.py) on the remote host."""
  setenv()
  rsync()

  if env.host[:6] == 'hopper':
    with prefix('module load numpy'):
      with cd(env.scratch + '/Combustion/SMC/analysis'):
        run('python speed-comp.py')
  elif env.host[:5] == 'gigan':
    with cd(env.scratch + '/Combustion/SMC/analysis'):
      run('/home/memmett/venv/base/bin/python speed-comp.py')


@task
def rsync():
  """Push (rsync) directories in env.rsync to env.host."""

  setenv()
  if env.host == 'localhost':
    return

  for src, dst in env.rsync:
      command = "rsync -avz -F {src}/ {host}:{dst}".format(
          host=env.host_rsync, src=src, dst=dst)
      local(command)


@task
def make(target=''):
  """Run make in the env.rwd directory on the remote host."""

  setenv()
  rsync()
  with cd(env.rwd):
    run('make %s' % target)


def setenv():
  """Setup Fabric and jobtools environment."""

  projects = '/home/memmett/projects/'

  if env.host[:6] == 'edison':
    env.scratch     = '/scratch/scratchdirs/memmett/'
    env.scheduler   = 'edison'
    env.host_string = 'edison.nersc.gov'
    env.host_rsync  = 'edison-s'
    env.exe         = 'mpi-ndarray'

    env.depth   = 6
    env.pernode = 4

    # XXX
    env.aprun_opts = [ '-cc numa_node' ]

  elif env.host[:5] == 'gigan':
    env.scratch     = '/scratch/memmett/'
    env.scheduler   = 'serial'
    env.host_string = 'gigan.lbl.gov'
    env.host_rsync  = 'gigan-s'
    env.exe         = 'mpi-ndarray'

    env.width = 1
    env.depth = 16
    
  env.rsync = [ (projects + 'libpfasst', env.scratch + 'libpfasst'), ]
